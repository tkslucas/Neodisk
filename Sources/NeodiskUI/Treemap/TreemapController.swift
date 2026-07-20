//
//  TreemapController.swift
//  Neodisk
//
//  Drives the treemap display: owns the live viewport (single source of
//  truth), schedules background scene builds/rasterization, and translates
//  view events into model actions. The view shows the last-rendered image
//  under an affine transform that tracks the live viewport, so gestures never
//  wait on a render; crisp renders land whenever the viewport has moved away
//  from the rendered one ("one render in flight, latest viewport wins").
//

import AppKit
import Foundation
import TreemapKit
import NeodiskKit

@MainActor
final class TreemapController {
    weak var view: TreemapNSView?
    weak var model: NeodiskViewModel?

    /// Cursor position (flipped view coordinates), or nil on exit — drives the
    /// hover tooltip's placement. Kept view-local; the shared model still owns
    /// the hovered node/cell state the status bar reads.
    var onHoverPoint: ((CGPoint?) -> Void)?
    /// Fires on the edges of a pan/zoom gesture so the pane can hide the
    /// tooltip while the map is moving (never per-frame — gesture frames must
    /// not round-trip through SwiftUI state).
    var onGestureActiveChange: ((Bool) -> Void)?

    /// Render-relevant inputs, compared as a unit so the flood of unrelated
    /// model updates (hover, selection, outline expansion) costs nothing.
    private struct Inputs: Equatable {
        var snapshotID: UUID?
        var rootID: String?
        var catalogID: UUID?
        var style: TreemapStyle = .cushion
        var colorMode: TreemapColorMode = .kind
        var highlight: TreemapHighlight?
        var expandedAggregateIDs: Set<String> = []
        var freeSpaceBytes: Int64?
        var hiddenSpaceBytes: Int64?
        var includingCloudOnly = false
        var palette: VizPalette = .standard
    }

    private(set) var viewport = TreemapViewport.identity
    private(set) var viewSize: CGSize = .zero
    /// Scene and image backing the content layer; `scene.viewport` is what
    /// the image was rendered at, which may trail `viewport`.
    private(set) var scene: TreemapScene?
    private(set) var image: CGImage?
    /// Pixel density the current image was rendered at; tracks the window's
    /// backingScaleFactor so non-Retina displays don't pay 4× the pixels.
    private(set) var renderedScale: CGFloat = 2

    private var inputs = Inputs()
    private var store: FileTreeStore?
    private var catalog: FileKindCatalog = .empty
    private var selectedNodeID: String?

    private var renderTask: Task<Void, Never>?
    private var gestureStartScale: CGFloat = 1
    private var gestureNetMagnification: CGFloat = 1

    /// Flat style has no viewport zoom: a pinch drills instead, one level per
    /// gesture (the shared "one drill per pinch" latch).
    private var flatPinchRecognizer = PinchDrillRecognizer()

    /// Flat-style drill morph: a root change within one snapshot animates —
    /// drilling in, the new map grows out of the container's former
    /// footprint; drilling out, the wider map pulls back from where you
    /// were. Captured at input time (drill-in needs the outgoing scene's
    /// rect), consumed when the matching render lands.
    private enum PendingDrillAnimation {
        case zoomIn(fromRect: CGRect)
        case zoomOut(previousRootID: String)
    }
    private var pendingDrillAnimation: PendingDrillAnimation?

    /// Whether a pan/zoom gesture is in progress; toggling notifies the pane
    /// (tooltip hides while true). Only the edges fire, never every frame.
    private var isGesturing = false {
        didSet {
            guard isGesturing != oldValue else { return }
            onGestureActiveChange?(isGesturing)
            // The hover ring hides with the tooltip and must come back when
            // the map settles, even if the pointer never moves again.
            view?.refreshHoverLayer()
        }
    }

    /// Last pointer position in view coordinates, nil once it leaves the
    /// map. Kept so the hover ring can re-resolve its cell whenever the
    /// scene or transform changes under a stationary pointer.
    private var hoverPoint: CGPoint?
    /// Momentum scroll/zoom has no explicit end event, so it self-clears after
    /// a brief idle; each event reschedules the reset.
    private var gestureIdleResetTask: Task<Void, Never>?

    // MARK: - Inputs from the representable

    func setInputs(
        snapshot: ScanSnapshot?,
        rootID: String?,
        catalog: FileKindCatalog,
        style: TreemapStyle = .cushion,
        colorMode: TreemapColorMode = .kind,
        highlight: TreemapHighlight? = nil,
        expandedAggregateIDs: Set<String>,
        freeSpaceBytes: Int64? = nil,
        hiddenSpaceBytes: Int64? = nil,
        includingCloudOnly: Bool = false,
        palette: VizPalette = .standard
    ) {
        let newInputs = Inputs(
            snapshotID: snapshot?.id,
            rootID: rootID,
            catalogID: catalog.buildID,
            style: style,
            colorMode: colorMode,
            highlight: highlight,
            expandedAggregateIDs: expandedAggregateIDs,
            freeSpaceBytes: freeSpaceBytes,
            hiddenSpaceBytes: hiddenSpaceBytes,
            includingCloudOnly: includingCloudOnly,
            palette: palette
        )
        guard newInputs != inputs else { return }

        // Arm the flat drill morph on a root change within the same
        // snapshot. The drill-in footprint must be read from the outgoing
        // scene now — it is gone once the new render lands; drill-out
        // resolves its rect from the incoming scene instead.
        if newInputs.style == .flat, inputs.style == .flat,
           newInputs.snapshotID != nil, newInputs.snapshotID == inputs.snapshotID,
           newInputs.rootID != inputs.rootID,
           let newRootID = newInputs.rootID, let previousRootID = inputs.rootID,
           let scene, let store {
            if let target = scene.rect(forNodeID: newRootID, in: store),
               target.width >= 1, target.height >= 1 {
                pendingDrillAnimation = .zoomIn(fromRect: target)
            } else {
                pendingDrillAnimation = .zoomOut(previousRootID: previousRootID)
            }
        } else {
            pendingDrillAnimation = nil
        }

        // A style change also resets the viewport: flat never zooms, and a
        // zoomed cushion viewport must not leak into it.
        if newInputs.rootID != inputs.rootID || newInputs.style != inputs.style || snapshot == nil {
            viewport = .identity
        }
        inputs = newInputs
        store = snapshot?.treeStore
        self.catalog = catalog
        cancelInFlightRender()
        startRender()
    }

    func setSelectedNode(_ nodeID: String?) {
        guard nodeID != selectedNodeID else { return }
        selectedNodeID = nodeID
        pushDisplay()
    }

    func setViewSize(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        viewport = viewport.clamped(viewSize: size)
        // No cancel: mid-resize renders land and are immediately superseded,
        // so the map tracks a splitter drag without ever going blank.
        requestRender()
    }

    /// The window moved to a display with a different pixel density —
    /// re-render at the new scale so the map stays crisp (or stops
    /// over-rendering on a non-Retina screen).
    func backingScaleChanged() {
        let scale = view?.window?.backingScaleFactor ?? 2
        guard scale != renderedScale else { return }
        cancelInFlightRender()
        startRender()
    }

    /// Light/dark switched: the flat style's fills are baked against the
    /// window background, so the pixels are stale — re-render.
    func appearanceChanged() {
        cancelInFlightRender()
        startRender()
    }

    /// The color the flat style's translucent fills are baked against —
    /// the window background resolved for the view's current appearance.
    /// Only the fill math uses it: the raster itself clears to transparent
    /// and the real (desktop-tinted) window backdrop shows through the
    /// gaps, where no constant could match the on-screen surface.
    private func windowBackgroundRGB() -> SIMD3<Float> {
        guard let view else { return TreemapRasterTarget.backgroundRGB }
        var cgColor = CGColor(gray: 0, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = NSColor.windowBackgroundColor.cgColor
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else {
            return TreemapRasterTarget.backgroundRGB
        }
        return SIMD3<Float>(
            Float(components[0]), Float(components[1]), Float(components[2])
        )
    }

    // MARK: - Display state

    /// Transform placing the rendered content under the live viewport.
    var displayTransform: CGAffineTransform {
        guard let scene else { return .identity }
        return viewport.displayTransform(fromRendered: scene.viewport)
    }

    /// Selection rect in rendered-scene coordinates (the content layer's
    /// space), or nil when nothing is selected or the node left the tree.
    var selectionRect: CGRect? {
        guard let scene, let store, let selectedNodeID else { return nil }
        return scene.rect(forNodeID: selectedNodeID, in: store)
    }

    /// Hovered cell's rect in rendered-scene coordinates, or nil when the
    /// pointer is off the map or a gesture is moving it (the ring hides
    /// with the tooltip). Resolved from the stored pointer position on
    /// every read, so it stays honest across re-renders and transforms.
    var hoverRect: CGRect? {
        guard !isGesturing, let hoverPoint else { return nil }
        return cell(at: hoverPoint)?.rect
    }

    // MARK: - Events from the view

    func hover(at point: CGPoint) {
        guard let model else { return }
        hoverPoint = point
        let cell = cell(at: point)
        model.hoveredNodeID = cell?.nodeID
        model.hoveredAggregate = cell?.aggregate
        model.hoveredCellIsFreeSpace = cell?.isFreeSpace == true
        model.hoveredCellIsHiddenSpace = cell?.isHiddenSpace == true
        onHoverPoint?(cell == nil ? nil : point)
        view?.refreshHoverLayer()
    }

    func hoverEnded() {
        hoverPoint = nil
        model?.hoveredNodeID = nil
        model?.hoveredAggregate = nil
        model?.hoveredCellIsFreeSpace = false
        model?.hoveredCellIsHiddenSpace = false
        onHoverPoint?(nil)
        view?.refreshHoverLayer()
    }

    func click(at point: CGPoint) {
        guard let model else { return }
        guard let cell = cell(at: point) else {
            model.select(nil)
            return
        }
        // The synthetic free/hidden-space cells represent no file; clicking
        // them clears the selection (same as the sunburst's arcs).
        if cell.isFreeSpace || cell.isHiddenSpace {
            model.select(nil)
            return
        }
        // Clicking a "smaller items" cell opens it up: its folder's children
        // render individually.
        if cell.aggregate != nil {
            model.expandAggregate(inFolder: cell.nodeID)
        }
        model.select(cell.nodeID)
    }

    /// Double-click. Cushion: reveal in Finder (mouse never drills there —
    /// navigation stays pinch/scroll and keyboard, see handleKey). Flat:
    /// folders are first-class canvas targets, so a folder double-click
    /// drills into it (aggregates carry their owning folder's id); files
    /// keep the reveal-in-Finder contract.
    func doubleClick(at point: CGPoint) {
        if inputs.style == .flat, let model, let cell = cell(at: point),
           cell.isDirectory, !cell.isFreeSpace, !cell.isHiddenSpace {
            model.drillIn(to: cell.nodeID)
            return
        }
        revealInFinder(at: point)
    }

    func revealInFinder(at point: CGPoint) {
        guard let model, let cell = cell(at: point),
              let node = model.store?.node(id: cell.nodeID),
              model.supportsFileActions(node) else { return }
        model.select(cell.nodeID)
        model.reveal(node)
    }

    func beginMagnify() {
        flatPinchRecognizer.begin()
        gestureStartScale = viewport.scale
        gestureNetMagnification = 1
        gestureIdleResetTask?.cancel()
        isGesturing = true
    }

    func magnify(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0 else { return }
        // Flat style: no viewport zoom — a pinch drills one level, latched
        // per gesture (spread into the folder under the cursor, squeeze up
        // to the parent), mirroring the sunburst's contract.
        if inputs.style == .flat {
            switch flatPinchRecognizer.accumulate(factor - 1) {
            case .drillIn: drillIntoFolder(at: anchor)
            case .drillOut: model?.zoomOut()
            case nil: break
            }
            return
        }
        gestureNetMagnification *= factor
        viewport = viewport.zoomed(by: factor, anchor: anchor, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
    }

    func endMagnify() {
        if inputs.style == .flat {
            flatPinchRecognizer.end()
            isGesturing = false
            return
        }
        // Pinching in while already at 1:1 steps out one folder.
        if gestureStartScale <= 1.001, viewport.scale <= 1.001, gestureNetMagnification < 0.9 {
            model?.zoomOut()
        }
        gestureNetMagnification = 1
        renderIfViewportMoved()
        isGesturing = false
    }

    /// Flat pinch-in drill target: the deepest folder-backed cell under the
    /// cursor — a container frame or header, an undivided directory, or a
    /// "smaller items" aggregate (its nodeID is the owning folder). Over a
    /// file the file's enclosing container is the deepest folder cell, so
    /// the drill still lands where the cursor points.
    private func drillIntoFolder(at point: CGPoint) {
        guard let model, let scene else { return }
        let scenePoint = point.applying(displayTransform.inverted())
        guard let target = scene.deepestDirectoryCell(at: scenePoint) else { return }
        model.drillIn(to: target.nodeID)
    }

    /// Option-scroll zoom (browser/maps style), anchored at the cursor.
    func scrollZoom(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0, inputs.style != .flat else { return }
        noteTransientGesture()
        viewport = viewport.zoomed(by: factor, anchor: anchor, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
    }

    /// Two-finger scroll pans the zoomed map. Returns false when the event
    /// should fall through to the responder chain (map at 1:1, or flat
    /// style — which never zooms or pans).
    func scroll(by delta: CGSize) -> Bool {
        guard inputs.style != .flat, viewport.scale > 1 else { return false }
        noteTransientGesture()
        viewport = viewport.panned(by: delta, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
        return true
    }

    /// Two-finger double-tap: zoom the viewport in a comfortable step.
    /// No-op in the flat style (no viewport zoom).
    func smartMagnify(at point: CGPoint) {
        guard inputs.style != .flat else { return }
        noteTransientGesture()
        viewport = viewport.zoomed(by: 2, anchor: point, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
    }

    /// Marks a momentum gesture active and (re)arms the idle reset that
    /// clears it once the map settles, so the tooltip returns on the next
    /// pointer move without needing an explicit gesture-end event.
    private func noteTransientGesture() {
        isGesturing = true
        gestureIdleResetTask?.cancel()
        gestureIdleResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.isGesturing = false
        }
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let model, let cell = cell(at: point),
              let node = model.store?.node(id: cell.nodeID) else { return nil }
        return NSMenu.fileNodeActions(for: node, model: model)
    }

    /// Spacebar Quick Look for the treemap: previews the selected node, so
    /// click-then-space works without ever focusing a sidebar list.
    func quickLookSelection() {
        guard let model else {
            NSSound.beep()
            return
        }
        model.quickLookSelection()
    }

    // MARK: - Keyboard navigation

    enum MoveDirection { case up, down, left, right }

    /// Routes a key event to a navigation action. Returns true when handled so
    /// the view stops it from propagating. Arrow keys move the selection
    /// spatially; ⌘↓/⌘↑ drill the map in/out; Return reveals in Finder.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let key = event.specialKey else { return false }
        let command = event.modifierFlags.contains(.command)
        switch key {
        case .upArrow:
            if command { beepUnless(model?.drillOut() == true) } else { moveSelection(.up) }
        case .downArrow:
            if command { beepUnless(model?.drillIntoSelection() == true) } else { moveSelection(.down) }
        case .leftArrow:
            moveSelection(.left)
        case .rightArrow:
            moveSelection(.right)
        case .carriageReturn, .enter, .newline:
            revealSelectionInFinder()
        default:
            return false
        }
        return true
    }

    /// Moves the selection to the nearest visible tile in `direction`. With no
    /// current selection, selects the largest tile so the keyboard has an
    /// anchor to move from.
    private func moveSelection(_ direction: MoveDirection) {
        guard let model, let scene else { return }
        // Free-space, hidden-space, and "smaller items" aggregate tiles
        // aren't real files; navigate only among concrete file/folder tiles.
        // Flat-style containers are excluded too — their centers sit on top
        // of their children, which would make spatial movement erratic.
        let tiles = scene.cells.filter {
            !$0.isFreeSpace && !$0.isHiddenSpace && $0.aggregate == nil && !$0.isContainer
        }
        guard !tiles.isEmpty else { return }

        guard let from = selectionRect.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
            if let largest = tiles.max(by: { $0.rect.area < $1.rect.area }) {
                model.select(largest.nodeID)
            }
            return
        }

        // Nearest tile whose center lies in `direction`, biased toward small
        // perpendicular offset so movement tracks the visual row/column. The
        // view is flipped, so up = smaller y, down = larger y.
        var best: (nodeID: String, score: CGFloat)?
        for tile in tiles where tile.nodeID != selectedNodeID {
            let to = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
            let dx = to.x - from.x, dy = to.y - from.y
            let primary: CGFloat
            let perpendicular: CGFloat
            switch direction {
            case .left: guard dx < -0.5 else { continue }; primary = -dx; perpendicular = abs(dy)
            case .right: guard dx > 0.5 else { continue }; primary = dx; perpendicular = abs(dy)
            case .up: guard dy < -0.5 else { continue }; primary = -dy; perpendicular = abs(dx)
            case .down: guard dy > 0.5 else { continue }; primary = dy; perpendicular = abs(dx)
            }
            let score = primary + 2 * perpendicular
            if best == nil || score < best!.score { best = (tile.nodeID, score) }
        }
        if let best { model.select(best.nodeID) } else { NSSound.beep() }
    }

    private func revealSelectionInFinder() {
        guard let model else {
            NSSound.beep()
            return
        }
        model.revealSelection()
    }

    /// The cell under a live view point, mapped back into the rendered
    /// scene's coordinates so hit-testing stays correct while the display
    /// transform is active.
    func cell(at viewPoint: CGPoint) -> TreemapCell? {
        guard let scene else { return nil }
        let scenePoint = viewPoint.applying(displayTransform.inverted())
        return scene.cell(at: scenePoint)
    }

    // MARK: - Render pipeline

    /// Starts a render unless one is already in flight; the in-flight one
    /// re-checks the viewport when it lands and chains the next render.
    private func requestRender() {
        guard renderTask == nil else { return }
        startRender()
    }

    /// Re-render after a viewport change, unless the current image already
    /// covers the new viewport crisply (pans inside the overscan margin).
    private func renderIfViewportMoved() {
        guard let scene else {
            requestRender()
            return
        }
        if scene.viewport == viewport && scene.size == viewSize { return }
        if scene.covers(viewport, viewSize: viewSize) { return }
        requestRender()
    }

    private func cancelInFlightRender() {
        renderTask?.cancel()
        renderTask = nil
    }

    private func startRender() {
        guard let store, let rootID = inputs.rootID,
              viewSize.width >= 1, viewSize.height >= 1 else {
            scene = nil
            image = nil
            pushDisplay(contentsChanged: true)
            return
        }

        let size = viewSize
        let viewport = viewport
        let catalog = catalog
        let style = inputs.style
        let colorMode = inputs.colorMode
        let highlight = inputs.highlight
        let expandedAggregateIDs = inputs.expandedAggregateIDs
        let freeSpaceBytes = inputs.freeSpaceBytes
        let hiddenSpaceBytes = inputs.hiddenSpaceBytes
        let includingCloudOnly = inputs.includingCloudOnly
        let palette = inputs.palette
        let scale = view?.window?.backingScaleFactor ?? 2
        let background = windowBackgroundRGB()
        renderTask = Task { [weak self] in
            // The detached task doesn't inherit cancellation, so a superseded
            // render (partial bursts, catalog landing mid-render) used to run
            // its full rasterization anyway and steal cores from the render
            // that replaces it. Forward the cancel and bail before rastering.
            let work = Task.detached(priority: .userInitiated) {
                () -> (TreemapScene, CGImage?)? in
                let scene = TreemapScene.build(
                    store: store, rootID: rootID, style: style, size: size, catalog: catalog,
                    colorMode: colorMode,
                    highlight: highlight,
                    expandedAggregateIDs: expandedAggregateIDs,
                    viewport: viewport,
                    freeSpaceBytes: freeSpaceBytes,
                    hiddenSpaceBytes: hiddenSpaceBytes,
                    includingCloudOnly: includingCloudOnly,
                    palette: palette,
                    background: background
                )
                guard !Task.isCancelled else { return nil }
                let image = switch style {
                case .cushion:
                    CushionTreemapRenderer.render(
                        cells: scene.cells, bounds: scene.renderBounds, scale: scale,
                        background: nil
                    )
                case .flat:
                    FlatTreemapRenderer.render(
                        cells: scene.cells, bounds: scene.renderBounds, scale: scale,
                        background: nil
                    )
                }
                return (scene, image)
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }

            guard let self, !Task.isCancelled, let result else { return }
            self.renderTask = nil
            self.scene = result.0
            self.image = result.1
            self.renderedScale = scale
            self.pushDisplay(contentsChanged: true)
            self.runPendingDrillAnimation()
            // Felt-time: the map's pixels just reached the layer tree. This is
            // the honest "tree displayed" moment for the current snapshot.
            if result.1 != nil {
                FeltTiming.noteTreemapDisplayed(snapshotID: self.inputs.snapshotID)
            }
            // The viewport may have moved on while this render was in
            // flight; chase it until display and viewport agree.
            self.renderIfViewportMoved()
        }
    }

    private func pushDisplay(contentsChanged: Bool = false) {
        view?.refreshDisplay(contentsChanged: contentsChanged)
    }

    /// Plays the armed drill morph once the render for the new root has
    /// landed (superseded renders are cancelled in setInputs, so a landed
    /// scene always matches the current inputs).
    private func runPendingDrillAnimation() {
        guard let pending = pendingDrillAnimation else { return }
        pendingDrillAnimation = nil
        guard inputs.style == .flat, let scene, scene.rootID == inputs.rootID else { return }
        let bounds = CGRect(origin: .zero, size: scene.size)
        guard bounds.width >= 1, bounds.height >= 1 else { return }

        let start: CGAffineTransform
        switch pending {
        case .zoomIn(let fromRect):
            // The new map starts squeezed into the drilled container's old
            // footprint and expands to fill the pane.
            start = Self.transform(mapping: bounds, to: fromRect)
        case .zoomOut(let previousRootID):
            // The wider map starts zoomed into where the old root now sits
            // and pulls back to rest.
            guard let store,
                  let previousRect = scene.rect(forNodeID: previousRootID, in: store),
                  previousRect.width >= 1, previousRect.height >= 1 else { return }
            start = Self.transform(mapping: previousRect, to: bounds)
        }
        view?.animateDrill(from: start)
    }

    /// The affine transform that draws content laid out over `from` into
    /// `to` (scale then translate).
    private static func transform(mapping from: CGRect, to: CGRect) -> CGAffineTransform {
        let sx = to.width / from.width
        let sy = to.height / from.height
        return CGAffineTransform(translationX: to.minX - from.minX * sx, y: to.minY - from.minY * sy)
            .scaledBy(x: sx, y: sy)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
