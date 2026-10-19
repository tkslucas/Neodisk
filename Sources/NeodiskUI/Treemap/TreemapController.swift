// The view shows the last image under a transform that tracks the live viewport, so gestures never
// wait on a render. One render in flight; the latest viewport wins.

import AppKit
import Foundation
import TreemapKit
import NeodiskKit
import NeodiskAppModel

@MainActor
final class TreemapController {
    weak var view: TreemapNSView?
    weak var model: NeodiskViewModel?

    /// Kept view-local; the shared model still owns the hovered node the status bar reads.
    var onHoverPoint: ((CGPoint?) -> Void)?
    /// Edges only, never per-frame: gesture frames must not round-trip through SwiftUI state.
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
        /// Workspace text scale: label gates and the flat header strip are
        /// sized from it, so a change rebuilds the scene like any other input.
        var labelScale: CGFloat = 1
    }

    private(set) var viewport = TreemapViewport.identity
    private(set) var viewSize: CGSize = .zero
    /// Scene and image backing the content layer; `scene.viewport` is what
    /// the image was rendered at, which may trail `viewport`.
    private(set) var scene: TreemapScene? {
        didSet { sceneQueries = SceneQueries() }
    }
    private(set) var image: CGImage?
    /// Pixel density the current image was rendered at; tracks the window's
    /// backingScaleFactor so non-Retina displays don't pay 4× the pixels.
    private(set) var renderedScale: CGFloat = 2

    private var inputs = Inputs()
    private var store: FileTreeStore? {
        didSet { sceneQueries = SceneQueries() }
    }
    private var catalog: FileKindCatalog = .empty
    private var selectedNodeID: String?

    /// Memoized per scene and store (both immutable). `selectionRect` is read on every display refresh,
    /// so re-running the layout down the selection path each time was pure repeat work.
    private struct SceneQueries {
        var navigationCandidates: [TreemapKeyboardNav.Candidate]?
        var selectionRect: (nodeID: String, rect: CGRect?)?
    }
    private var sceneQueries = SceneQueries()

    private var renderTask: Task<Void, Never>?
    /// The snapshot and size of the image on screen, so a resize can tell a
    /// render that only chases the size from one bringing a newer tree.
    private var displayedSnapshotID: UUID?
    private var displayedViewSize: CGSize = .zero
    /// A settled resize arrived while a content render was still running:
    /// render at the exact size once that one lands.
    private var needsExactSizeRender = false
    /// Exact pane-size rendering waits for a short quiet period; the last
    /// complete image stretches through `displayTransform` in the meantime.
    private var resizeSettleTask: Task<Void, Never>?
    private var gestureStartScale: CGFloat = 1
    private var gestureNetMagnification: CGFloat = 1

    /// Flat style has no viewport zoom: a pinch drills instead, one level per
    /// gesture (the shared "one drill per pinch" latch).
    private var flatPinchRecognizer = PinchDrillRecognizer()

    /// Captured at input time because drill-in needs the outgoing scene's rect; consumed when the render lands.
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
            if !isGesturing { resolveHoverAfterDisplayChange() }
            view?.refreshHoverLayer()
        }
    }

    /// Kept so the hover ring can re-resolve when the scene changes under a stationary pointer.
    private var hoverPoint: CGPoint?
    /// Cell resolved by the last pointer hit test. Its rect feeds the hover
    /// layer directly, so moving inside one cell never hit-tests twice.
    private var hoveredCell: HoveredCell?

    private struct HoveredCell: Equatable {
        let nodeID: String
        let rect: CGRect
        let aggregate: TreemapCell.AggregateInfo?
        let isFreeSpace: Bool
        let isHiddenSpace: Bool
        let swatchRGB: SIMD3<Float>

        init(_ cell: TreemapCell) {
            nodeID = cell.nodeID
            rect = cell.rect
            aggregate = cell.aggregate
            isFreeSpace = cell.isFreeSpace
            isHiddenSpace = cell.isHiddenSpace
            swatchRGB = cell.swatchRGB
        }

        var modelValue: VisualizationHover {
            if isFreeSpace { return .freeSpace(swatchRGB: swatchRGB) }
            if isHiddenSpace { return .hiddenSpace(swatchRGB: swatchRGB) }
            if let aggregate {
                return .aggregate(
                    folderID: nodeID,
                    itemCount: aggregate.itemCount,
                    totalSize: aggregate.totalSize,
                    swatchRGB: swatchRGB
                )
            }
            return .node(id: nodeID, swatchRGB: swatchRGB)
        }
    }
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
        palette: VizPalette = .standard,
        labelScale: CGFloat = 1
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
            palette: palette,
            labelScale: labelScale
        )
        guard newInputs != inputs else { return }
        if snapshot?.isComplete == true, FeltTiming.engineFinishedProfileSince != 0 {
            ScanProfile.addNamed(
                newInputs.snapshotID == inputs.snapshotID ? "app.finalInputsChanged" : "app.finalInputsArrived",
                since: FeltTiming.engineFinishedProfileSince
            )
        }

        // The drill-in footprint must be read from the outgoing scene now; it is gone once the new render
        // lands.
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
        cancelDeferredResizeRender()
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
        if ScanProfile.isEnabled, FeltTiming.engineFinishedProfileSince != 0 {
            ScanTiming.note("finalRender resize \(viewSize) -> \(size) t=\((ScanProfile.now() &- FeltTiming.engineFinishedProfileSince) / 1_000_000)ms")
        }
        viewSize = size
        viewport = viewport.clamped(viewSize: size)
        guard size.width >= 1, size.height >= 1 else {
            cancelDeferredResizeRender()
            cancelInFlightRender()
            startRender()
            return
        }
        guard scene != nil, image != nil else {
            // First display has nothing useful to stretch; render immediately.
            requestRender()
            return
        }

        // A render bringing a newer tree still lands, else a scan's final map was thrown away
        // and the user waited out the settle delay for it.
        if !renderBringsNewContent {
            cancelInFlightRender()
        }
        pushDisplay()
        scheduleSettledResizeRender()
    }

    func backingScaleChanged() {
        let scale = view?.window?.backingScaleFactor ?? 2
        guard scale != renderedScale else { return }
        cancelDeferredResizeRender()
        cancelInFlightRender()
        startRender()
    }

    /// Light/dark switched: the flat style's fills are baked against the
    /// window background, so the pixels are stale — re-render.
    func appearanceChanged() {
        cancelDeferredResizeRender()
        cancelInFlightRender()
        startRender()
    }

    /// Only the fill math uses it: the raster clears to transparent so the real, desktop-tinted backdrop
    /// shows through the gaps, which no constant could match.
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
        return TreemapResizePolicy.displayTransform(
            liveViewport: viewport,
            liveSize: viewSize,
            renderedViewport: scene.viewport,
            renderedSize: scene.size
        )
    }

    /// Selection rect in rendered-scene coordinates (the content layer's
    /// space), or nil when nothing is selected or the node left the tree.
    var selectionRect: CGRect? {
        guard let scene, let store, let selectedNodeID else { return nil }
        if let memo = sceneQueries.selectionRect, memo.nodeID == selectedNodeID {
            return memo.rect
        }
        let rect = scene.rect(forNodeID: selectedNodeID, in: store)
        sceneQueries.selectionRect = (selectedNodeID, rect)
        return rect
    }

    /// Nil while a gesture moves the map (the ring hides with the tooltip).
    var hoverRect: CGRect? {
        guard !isGesturing else { return nil }
        return hoveredCell?.rect
    }

    // MARK: - Events from the view

    func hover(at point: CGPoint) {
        guard model != nil else { return }
        hoverPoint = point
        let changed = setHoveredCell(cell(at: point))
        onHoverPoint?(hoveredCell == nil ? nil : point)
        if changed { view?.refreshHoverLayer() }
    }

    func hoverEnded() {
        let hadHover = hoveredCell != nil
        hoverPoint = nil
        hoveredCell = nil
        model?.setVisualizationHover(nil)
        onHoverPoint?(nil)
        if hadHover { view?.refreshHoverLayer() }
    }

    @discardableResult
    private func setHoveredCell(_ cell: TreemapCell?) -> Bool {
        let next = cell.map(HoveredCell.init)
        guard next != hoveredCell else { return false }
        hoveredCell = next
        model?.setVisualizationHover(next?.modelValue)
        return true
    }

    /// Re-resolves once at the boundary, never again while the pointer stays inside the same cell.
    private func resolveHoverAfterDisplayChange() {
        guard let hoverPoint else { return }
        _ = setHoveredCell(cell(at: hoverPoint))
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

    /// Cushion reveals in Finder (mouse never drills there). Flat drills into folders, including aggregates,
    /// which carry their owning folder's id.
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
        // Flat style has no viewport zoom: a pinch drills one level, latched per gesture.
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

    /// Over a file the deepest folder cell is its enclosing container, so the drill lands where the cursor is.
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

    /// False lets the event fall through: map at 1:1, or flat style, which never pans.
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

    /// The idle reset clears it once the map settles, since momentum gestures send no explicit end event.
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

    typealias MoveDirection = TreemapKeyboardNav.Direction

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

    /// With no selection, selects the largest tile so the keyboard has an anchor.
    private func moveSelection(_ direction: MoveDirection) {
        guard let model, let scene else { return }
        let candidates: [TreemapKeyboardNav.Candidate]
        if let cached = sceneQueries.navigationCandidates {
            candidates = cached
        } else {
            candidates = TreemapKeyboardNav.candidates(in: scene.cells)
            sceneQueries.navigationCandidates = candidates
        }
        guard !candidates.isEmpty else { return }

        guard let from = selectionRect.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
            if let largest = TreemapKeyboardNav.largest(in: candidates) {
                model.select(largest)
            }
            return
        }

        if let target = TreemapKeyboardNav.target(
            from: from, direction: direction, excluding: selectedNodeID, in: candidates
        ) {
            model.select(target)
        } else {
            NSSound.beep()
        }
    }

    private func revealSelectionInFinder() {
        guard let model else {
            NSSound.beep()
            return
        }
        model.revealSelection()
    }

    /// Maps back into rendered-scene coordinates so hit-testing holds while the display transform is active.
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
        if renderTask != nil { ScanProfile.addNamed("app.treemapRenderCancelled", since: ScanProfile.now()) }
        renderTask?.cancel()
        renderTask = nil
    }

    private func cancelDeferredResizeRender() {
        resizeSettleTask?.cancel()
        resizeSettleTask = nil
    }

    private func scheduleSettledResizeRender() {
        resizeSettleTask?.cancel()
        resizeSettleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: TreemapResizePolicy.settleDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.resizeSettleTask = nil
            if self.renderBringsNewContent {
                self.needsExactSizeRender = true
                return
            }
            self.cancelInFlightRender()
            self.startRender()
        }
    }

    private static let renderQueue = DispatchQueue(
        label: "com.neodisk.treemap-render",
        qos: .userInteractive,
        attributes: .concurrent
    )

    private var renderBringsNewContent: Bool {
        renderTask != nil && inputs.snapshotID != displayedSnapshotID
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
        let labelScale = inputs.labelScale
        let scale = view?.window?.backingScaleFactor ?? 2
        let background = windowBackgroundRGB()
        let requestedSince = ScanProfile.now()
        let traceFinal = FeltTiming.engineFinishedProfileSince
        @Sendable func trace(_ step: String) {
            guard ScanProfile.isEnabled, traceFinal != 0 else { return }
            ScanTiming.note("finalRender \(step) t=\((ScanProfile.now() &- traceFinal) / 1_000_000)ms")
        }
        trace("requested")
        let cancellation = TreemapRenderCancellation()
        let work: @Sendable () -> (TreemapScene, CGImage?)? = {
            trace("workStarted")
            let sceneSince = ScanProfile.now()
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
                background: background,
                labelScale: labelScale
            )
            ScanProfile.addNamed("app.treemapScene", since: sceneSince)
            trace("sceneBuilt")
            guard !cancellation.isCancelled else { return nil }
            let rasterSince = ScanProfile.now()
            defer { ScanProfile.addNamed("app.treemapRaster", since: rasterSince) }
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
        // Started now: right after a scan the main thread is busy ~90 ms and the task could not start until
        // then.
        let pending = TreemapRenderResult()
        Self.renderQueue.async { pending.fulfill(work()) }
        renderTask = Task { [weak self] in
            // No inherited cancellation, so forward it or a superseded render steals cores. Own queue: on the
            // cooperative pool the final map waited ~90 ms behind stats jobs.
            let result = await withTaskCancellationHandler {
                await pending.value
            } onCancel: {
                cancellation.cancel()
            }

            trace(Task.isCancelled ? "cancelled" : "resultOnMain")
            guard let self, !Task.isCancelled, let result else { return }
            let displaySince = ScanProfile.now()
            defer { ScanProfile.addNamed("app.treemapDisplay", since: displaySince) }
            self.renderTask = nil
            self.scene = result.0
            self.image = result.1
            self.renderedScale = scale
            self.displayedSnapshotID = self.inputs.snapshotID
            self.displayedViewSize = size
            self.resolveHoverAfterDisplayChange()
            self.pushDisplay(contentsChanged: true)
            self.runPendingDrillAnimation()
            // Felt-time: the map's pixels just reached the layer tree. This is
            // the honest "tree displayed" moment for the current snapshot.
            if result.1 != nil {
                FeltTiming.noteTreemapDisplayed(snapshotID: self.inputs.snapshotID)
                ScanProfile.addNamed("app.treemapRequestToDisplay", since: requestedSince)
            }
            if self.needsExactSizeRender {
                self.needsExactSizeRender = false
                if self.displayedViewSize != self.viewSize {
                    self.startRender()
                    return
                }
            }
            // The viewport may have moved on while this render was in
            // flight; chase it until display and viewport agree.
            self.renderIfViewportMoved()
        }
    }

    private func pushDisplay(contentsChanged: Bool = false) {
        view?.refreshDisplay(contentsChanged: contentsChanged)
    }

    /// Superseded renders are cancelled in setInputs, so a landed scene always matches the current inputs.
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

/// Cancellation for a render running outside Swift concurrency.
private final class TreemapRenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A render's result, produced on the render queue and awaited on the main
/// actor; whichever comes second hands it over.
private final class TreemapRenderResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (TreemapScene, CGImage?)??
    private var waiter: CheckedContinuation<(TreemapScene, CGImage?)?, Never>?

    func fulfill(_ value: (TreemapScene, CGImage?)?) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: value)
        } else {
            result = .some(value)
            lock.unlock()
        }
    }

    var value: (TreemapScene, CGImage?)? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}
