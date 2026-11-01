// Scene building, rasterization and label layout run off the main thread into one device bitmap plus one label
// image; hover, selection and focus draw over them per frame, so pointer motion never re-rasterizes. Cushion
// zooms like an image until the sharper render lands.

import CNeodiskCanvas
import Foundation
import NeodiskAppModel
import NeodiskKit
import TreemapKit
import WinSDK

@MainActor
final class TreemapPresenter {
    private unowned let host: CanvasHost
    private var model: VizCanvasModel { host.model }

    /// Everything a frame depends on; a render starts only when it changes.
    struct RenderInputs: Equatable, Sendable {
        var storeGeneration: Int
        var rootID: String
        var size: CGSize
        var scale: Double
        var style: TreemapStyle
        var catalogBuildID: Foundation.UUID
        var colorMode: TreemapColorMode
        var highlight: TreemapHighlight?
        var paletteID: String
        var viewport: TreemapViewport
        var expandedAggregateIDs: Set<String>
        var freeSpaceBytes: Int64?
        var hiddenSpaceBytes: Int64?
        var isDark: Bool
        var background: SIMD3<Float>
    }

    private struct Frame {
        let inputs: RenderInputs
        let scene: TreemapScene
        let image: CanvasImage
        /// Nil when nothing fits, or while the canvas size moved on before the frame landed.
        let labels: CanvasImage?
    }

    /// What a background render hands back.
    private struct Rendered: @unchecked Sendable {
        let scene: TreemapScene
        let raster: (pixels: [UInt8], width: Int, height: Int)?
        let labels: [(text: CanvasText, origin: CGPoint)]
    }

    private var frame: Frame?
    private var viewport = TreemapViewport.identity
    private var inFlight: RenderInputs?
    /// What the frame drew, for the arrow keys; built on the first press after each frame.
    private var renderedIDs: Set<String>?
    private var selectionRects: (selection: NodeSelection, rects: [CGRect])?
    /// The cell under the pointer, in scene coordinates.
    private var hoveredRect: CGRect?
    private var hoverPoint: CGPoint?
    private var lastRootID: String?
    private var lastStoreGeneration: Int?
    /// Where a wheel zoom is gliding to, anchored at the pointer.
    private var zoomTarget: (viewport: TreemapViewport, anchor: CGPoint)?
    private var lastGlideStep: ContinuousClock.Instant?
    private var dragStart: (point: CGPoint, viewport: TreemapViewport)?
    private(set) var isPanning = false
    private var wheelDrill = WheelDrillLatch()

    init(host: CanvasHost) {
        self.host = host
    }

    // MARK: - Model changes

    /// Re-checks render inputs (cheap when nothing moved) and repaints overlays.
    func modelDidChange() {
        // A new tree or focus starts unzoomed.
        let rootID = model.focusedRootID
        if rootID != lastRootID || (model.store == nil) != (lastStoreGeneration == nil) {
            lastRootID = rootID
            stopZoomAnimation()
            viewport = .identity
        }
        lastStoreGeneration = model.store == nil ? nil : model.storeGeneration
        requestRender()
        host.invalidate()
    }

    func deviceLost() {
        frame = nil
        inFlight = nil
        requestRender()
    }

    var hasFrame: Bool { frame != nil }
    var isAnimating: Bool { zoomTarget != nil }

    // MARK: - Rendering

    private func currentInputs() -> RenderInputs? {
        guard let store = model.store, let rootID = model.focusedRootID else { return nil }
        let size = host.viewSize
        guard size.width >= 1, size.height >= 1 else { return nil }
        return RenderInputs(
            storeGeneration: model.storeGeneration,
            rootID: store.node(id: rootID) == nil ? store.rootID : rootID,
            size: size,
            scale: host.scale,
            style: model.treemapStyle,
            catalogBuildID: model.catalog.buildID,
            colorMode: model.colorMode,
            highlight: model.highlight,
            paletteID: model.palette.id,
            viewport: viewport,
            expandedAggregateIDs: model.expandedAggregateIDs,
            freeSpaceBytes: model.vizFreeSpaceBytes,
            hiddenSpaceBytes: model.vizHiddenSpaceBytes,
            isDark: model.isDarkTheme,
            background: model.vizBackgroundRGB
        )
    }

    /// A render that finishes stale starts the next one itself.
    func requestRender() {
        guard let inputs = currentInputs() else {
            if model.store == nil, frame != nil {
                frame = nil
                resolveHover()
                host.invalidate()
            }
            return
        }
        guard host.isShowing(self), host.device != nil else { return }
        guard inputs != frame?.inputs, inputs != inFlight, inFlight == nil else { return }
        guard let store = model.store else { return }
        inFlight = inputs

        let catalog = model.catalog
        let palette = model.palette
        let mailbox = host.mailbox
        let stats = host.stats
        host.runInBackground { [weak self] in
            let rendered = Self.render(inputs: inputs, store: store, catalog: catalog, palette: palette, stats: stats)
            mailbox.post { [weak self] in
                self?.land(rendered, inputs: inputs)
            }
        }
    }

    private nonisolated static func render(
        inputs: RenderInputs,
        store: FileTreeStore,
        catalog: FileKindCatalog,
        palette: VizPalette,
        stats: CanvasStats
    ) -> Rendered {
        let start = ContinuousClock.now
        let scene = TreemapScene.build(
            store: store,
            rootID: inputs.rootID,
            style: inputs.style,
            size: inputs.size,
            catalog: catalog,
            colorMode: inputs.colorMode,
            highlight: inputs.highlight,
            expandedAggregateIDs: inputs.expandedAggregateIDs,
            viewport: inputs.viewport,
            freeSpaceBytes: inputs.freeSpaceBytes,
            hiddenSpaceBytes: inputs.hiddenSpaceBytes,
            palette: palette,
            background: inputs.background
        )
        let built = ContinuousClock.now
        // Gaps clear to the canvas background, which the frame also clears to.
        let raster = inputs.style == .flat
            ? FlatTreemapRenderer.rasterizeRGBA(
                cells: scene.cells, bounds: scene.renderBounds, scale: inputs.scale, background: inputs.background)
            : CushionTreemapRenderer.rasterizeRGBA(
                cells: scene.cells, bounds: scene.renderBounds, scale: inputs.scale, background: inputs.background)
        let rasterized = ContinuousClock.now
        let labels = layoutLabels(scene)
        stats.record("treemap.scene", ms: Clock.milliseconds(since: start) - Clock.milliseconds(since: built))
        stats.record("treemap.raster", ms: Clock.milliseconds(since: built) - Clock.milliseconds(since: rasterized))
        stats.record("treemap.labels", ms: Clock.milliseconds(since: rasterized))
        stats.record("treemap.render", ms: Clock.milliseconds(since: start))
        stats.record("treemap.cells", ms: Double(scene.cells.count))
        return Rendered(scene: scene, raster: raster, labels: labels)
    }

    /// Label size in DIPs: the UI font a step down, as the other apps draw cell names.
    nonisolated static let labelFontSize = 12.0
    /// A truncated label must keep this many characters to be worth drawing ("A…" is clutter).
    private nonisolated static let minUsefulTruncatedCharacters = 4

    private nonisolated static func layoutLabels(_ scene: TreemapScene) -> [(text: CanvasText, origin: CGPoint)] {
        var labels: [(text: CanvasText, origin: CGPoint)] = []
        labels.reserveCapacity(scene.labels.count)
        for label in scene.labels {
            let inset: Double = label.isHeader ? 0 : 4
            let width = max(label.rect.width - 2 * inset, 10)
            guard let text = CanvasText(
                label.text, size: labelFontSize, bold: label.isHeader, maxWidth: width,
                alignment: label.isHeader ? .leading : .center
            ) else { continue }
            if text.isTruncated {
                // Keep the label only if the first few characters fit.
                let prefix = String(label.text.prefix(minUsefulTruncatedCharacters)) + "\u{2026}"
                if CanvasText.measure(prefix, size: labelFontSize, bold: label.isHeader) > width { continue }
            }
            labels.append((text, CGPoint(x: label.rect.minX + inset, y: label.rect.midY - text.height / 2)))
        }
        return labels
    }

    private func land(_ rendered: Rendered, inputs: RenderInputs) {
        inFlight = nil
        if let raster = rendered.raster, let device = host.device {
            let start = ContinuousClock.now
            guard let image = device.makeImage(
                pixels: raster.pixels, width: raster.width, height: raster.height, stride: raster.width * 4, isBGRA: false
            ) else { return }
            let uploaded = ContinuousClock.now
            // The label image covers the canvas, so it's only valid at the size it was laid out for.
            var labels: CanvasImage?
            if inputs.size == host.viewSize, inputs.scale == host.scale {
                labels = device.renderTexts(
                    rendered.labels,
                    color: inputs.isDark ? .white : NDColor.black.withAlpha(0.85),
                    halo: inputs.isDark ? (2, NDColor.black.withAlpha(0.9)) : nil
                )
            }
            host.stats.record("treemap.upload", ms: Clock.milliseconds(since: start) - Clock.milliseconds(since: uploaded))
            host.stats.record("treemap.labelImage", ms: Clock.milliseconds(since: uploaded))
            frame = Frame(inputs: inputs, scene: rendered.scene, image: image, labels: labels)
            selectionRects = nil
            renderedIDs = nil
            host.invalidate()
        } else if rendered.scene.cells.isEmpty {
            frame = nil
            host.invalidate()
        }
        // The cells under a stationary pointer may have changed.
        resolveHover()
        // Inputs moved on while this render ran (resize, zoom, scan progress): render again for the latest.
        if currentInputs() != inputs {
            requestRender()
        }
    }

    // MARK: - Drawing

    func draw(into canvas: D2DCanvas, size: CGSize) {
        advanceZoomGlide()
        guard let frame else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let mapping = displayMapping(for: frame)
        canvas.pushClip(bounds)
        defer { canvas.popClip() }

        // A resize or zoom in progress stretches the last crisp frame until the next lands.
        canvas.draw(frame.image, in: mapped(frame.scene.renderBounds, mapping), smooth: true)
        if mapping == .identity, let labels = frame.labels {
            canvas.draw(labels, in: CGRect(origin: .zero, size: frame.inputs.size), smooth: false)
        }

        if let hoveredRect, model.hoveredNodeID != nil {
            canvas.stroke(mapped(hoveredRect, mapping), width: 1.5, NDColor.white.withAlpha(0.8))
        }
        // The same ring for every selected item.
        if let store = model.store {
            let accent = NDColor(model.accentRGB)
            for rect in selectionRects(in: frame, store: store) {
                canvas.stroke(mapped(rect, mapping).insetBy(dx: -1, dy: -1), width: 3, .white)
                canvas.stroke(mapped(rect, mapping), width: 2, accent)
            }
        }
        if host.showsFocusRing {
            canvas.stroke(bounds, width: 2, NDColor(model.accentRGB).withAlpha(0.9))
        }
    }

    private func selectionRects(in frame: Frame, store: FileTreeStore) -> [CGRect] {
        let selection = model.selection
        if let cached = selectionRects, cached.selection == selection { return cached.rects }
        // One layout per folder however many items share it; items merged into one "smaller items" cell share
        // its ring.
        let byID = frame.scene.rects(forNodeIDs: selection.ids, in: store)
        var seen = Set<[CGFloat]>()
        let rects = selection.ids.compactMap { byID[$0] }.filter {
            seen.insert([$0.minX, $0.minY, $0.width, $0.height]).inserted
        }
        selectionRects = (selection, rects)
        return rects
    }

    /// Maps the rendered frame into the live viewport while a zoom or resize outruns re-rendering.
    private func displayMapping(for frame: Frame) -> TreemapDisplayMapping {
        TreemapResizePolicy.displayMapping(
            liveViewport: viewport,
            liveSize: host.viewSize,
            renderedViewport: frame.inputs.viewport,
            renderedSize: frame.inputs.size
        )
    }

    private func mapped(_ rect: CGRect, _ mapping: TreemapDisplayMapping) -> CGRect {
        guard mapping != .identity else { return rect }
        let origin = mapping.apply(to: rect.origin)
        let corner = mapping.apply(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }

    private func scenePoint(_ point: CGPoint, in frame: Frame) -> CGPoint {
        let mapping = displayMapping(for: frame)
        return mapping == .identity ? point : CGPoint(
            x: (point.x - mapping.translationX) / mapping.scaleX,
            y: (point.y - mapping.translationY) / mapping.scaleY
        )
    }

    /// The scene cell under a point in live view coordinates.
    private func cell(at point: CGPoint) -> TreemapCell? {
        guard let frame else { return nil }
        return frame.scene.cell(at: scenePoint(point, in: frame))
    }

    // MARK: - Pointer

    func pointerMoved(to point: CGPoint?) {
        if let start = dragStart, let point {
            let dx = point.x - start.point.x
            let dy = point.y - start.point.y
            if !isPanning, dx * dx + dy * dy >= 16 {
                isPanning = true
                stopZoomAnimation()
            }
            if isPanning {
                setViewport(start.viewport.panned(by: CGSize(width: dx, height: dy), viewSize: host.viewSize))
                return
            }
        }
        hoverPoint = point
        resolveHover()
    }

    /// Hit-tests the last pointer position against the frame on screen.
    func resolveHover() {
        let cell = hoverPoint.flatMap { cell(at: $0) }
        let hovered = cell.flatMap { $0.isFreeSpace || $0.isHiddenSpace ? nil : $0.nodeID }
        let rectChanged = hoveredRect != cell?.rect
        if rectChanged {
            hoveredRect = cell?.rect
            host.invalidate()
        }
        if model.hoveredNodeID != hovered {
            model.hoveredNodeID = hovered
            host.invalidate()
        }
        if rectChanged {
            model.vizStatusText(cell.map(statusText(for:)))
        }
    }

    func pointerDown(button: Int, clickCount: Int, at point: CGPoint, ctrl: Bool, shift: Bool) {
        let click = MapClick(command: ctrl, shift: shift)
        if button == 1, clickCount == 1, !isFlat, viewport.scale > 1.0001 {
            // Dragging a zoomed map pans it, like an image.
            dragStart = (point, viewport)
            isPanning = false
        }
        guard let cell = cell(at: point) else {
            if button == 1, click == .replace { model.select(nil) }
            return
        }
        if cell.isFreeSpace || cell.isHiddenSpace {
            if click == .replace { model.select(nil) }
            return
        }
        switch button {
        case 1 where clickCount == 1 && click == .toggle:
            // Ctrl- or Shift-click: the item joins or leaves. A "smaller items" cell opens instead; it stands for
            // its folder, which a toggle mustn't add.
            if cell.aggregate != nil {
                model.expandedAggregateIDs.insert(cell.nodeID)
            } else {
                model.toggleSelection(cell.nodeID)
            }
        case 2:
            // The menu acts on the selection: a cell outside it becomes it.
            if !model.selection.contains(cell.nodeID) { model.select(cell.nodeID) }
        case 1 where clickCount >= 2:
            // As in the other apps: flat folders drill in; cushion cells show the item in File Explorer and never
            // drill by mouse.
            if isFlat, cell.isDirectory {
                if !model.drillIn(to: cell.nodeID) { host.beep() }
            } else if model.store?.node(id: cell.nodeID) != nil {
                model.select(cell.nodeID)
                model.vizShowInExplorer(nodeID: cell.nodeID)
            }
        case 1:
            // Clicking a "smaller items" cell opens its folder's tail up.
            if cell.aggregate != nil {
                model.expandedAggregateIDs.insert(cell.nodeID)
            }
            model.select(cell.nodeID)
        default:
            break
        }
    }

    func pointerUp() {
        dragStart = nil
        isPanning = false
    }

    /// Whether the context menu at this point offers to move to the Recycle Bin.
    func menuIncludesTrash(at point: CGPoint?) -> Bool {
        guard let point, let cell = cell(at: point) else { return true }
        return cell.aggregate == nil
    }

    /// Where a keyboard-invoked menu opens: the primary selection's cell.
    func menuAnchor() -> CGPoint? {
        guard let frame, let store = model.store, let id = model.selection.primaryID,
              let rect = frame.scene.rect(forNodeID: id, in: store) else { return nil }
        let shown = mapped(rect, displayMapping(for: frame))
        return CGPoint(x: shown.midX, y: shown.midY)
    }

    // MARK: - Wheel and zoom

    private var isFlat: Bool { model.treemapStyle == .flat }

    /// Magnification per wheel notch.
    private static let wheelZoomStep = 1.25
    /// Time constant of the glide toward a wheel zoom target, in seconds.
    private static let glideTimeConstant = 0.05

    /// Ctrl+wheel (and touchpad pinch, which Windows sends as one) zooms at the pointer, or drills on the flat
    /// map; the plain wheel pans a zoomed map. `notches` is positive away from the user.
    func wheel(notches: Double, horizontal: Bool, at point: CGPoint, ctrl: Bool, shift: Bool) -> Bool {
        guard frame != nil else { return false }
        if ctrl, !horizontal {
            if isFlat {
                switch wheelDrill.feed(notches: notches) {
                case .drillIn?: drillIntoFolder(at: point)
                case .drillOut?: model.focusOut()
                case nil: break
                }
                return true
            }
            let current = zoomTarget?.viewport ?? viewport
            // Zooming out of a map that's already whole steps out a folder.
            if notches < 0, current.scale <= 1.001 {
                if wheelDrill.feed(notches: notches) == .drillOut {
                    model.focusOut()
                }
                return true
            }
            let target = current.zoomed(by: pow(Self.wheelZoomStep, notches), anchor: point, viewSize: host.viewSize)
            glideZoom(to: target.clamped(viewSize: host.viewSize), anchor: point)
            return true
        }
        guard !isFlat, viewport.scale > 1.0001 else { return false }
        stopZoomAnimation()
        let step = 40.0 * notches
        let delta = horizontal || shift ? CGSize(width: -step, height: 0) : CGSize(width: 0, height: step)
        setViewport(viewport.panned(by: delta, viewSize: host.viewSize))
        return true
    }

    private func setViewport(_ newViewport: TreemapViewport) {
        let clamped = newViewport.clamped(viewSize: host.viewSize)
        guard clamped != viewport else { return }
        viewport = clamped
        host.invalidate()
        requestRender()
    }

    private func glideZoom(to target: TreemapViewport, anchor: CGPoint) {
        if zoomTarget == nil { lastGlideStep = nil }
        zoomTarget = (target, anchor)
        host.invalidate()
    }

    /// One frame of the glide: close a fixed share of the remaining zoom in log scale around the anchor, so it
    /// eases out wherever it started.
    private func advanceZoomGlide() {
        guard let target = zoomTarget else { return }
        let now = ContinuousClock.now
        let elapsed = lastGlideStep.map { Clock.milliseconds(since: $0) / 1000 } ?? 1.0 / 60
        lastGlideStep = now
        let progress = 1 - exp(-min(elapsed, 0.1) / Self.glideTimeConstant)
        let remaining = target.viewport.scale / viewport.scale
        if abs(remaining - 1) < 0.002 {
            zoomTarget = nil
            setViewport(target.viewport)
            return
        }
        setViewport(viewport.zoomed(by: pow(remaining, progress), anchor: target.anchor, viewSize: host.viewSize))
    }

    private func stopZoomAnimation() {
        zoomTarget = nil
        lastGlideStep = nil
    }

    /// The deepest folder-backed cell under the point (a "smaller items" cell's ID is its folder's).
    private func drillIntoFolder(at point: CGPoint) {
        guard let frame else { return }
        guard let target = frame.scene.deepestDirectoryCell(at: scenePoint(point, in: frame)) else { return }
        if !model.drillIn(to: target.nodeID) { host.beep() }
    }

    func didResize() {
        viewport = viewport.clamped(viewSize: host.viewSize)
        requestRender()
    }

    // MARK: - Keys

    func keyDown(vk: Int32, ctrl: Bool, shift: Bool, alt: Bool) -> Bool {
        guard let frame, let store = model.store else { return false }
        if vk == 0x41, ctrl, !shift, !alt {  // Ctrl+A
            if !model.selectAllInMap() { host.beep() }
            return true
        }
        switch vk {
        case VK_RETURN:
            if !model.drillIntoSelection() { host.beep() }
        case VK_BACK:
            model.focusOut()
        case VK_ESCAPE:
            // A zoomed map resets first; otherwise the window's Escape deselects.
            guard viewport != .identity else { return false }
            stopZoomAnimation()
            setViewport(.identity)
        default:
            guard let move = Self.treeMove(for: vk) else { return false }
            // Right after a drill the frame still shows the old root: then every item counts.
            var isRendered: ((String) -> Bool)?
            if frame.scene.rootID == model.focusedRootID {
                let rendered = renderedIDs ?? TreeKeyboardNav.renderedIDs(in: frame.scene.cells, store: store)
                renderedIDs = rendered
                isRendered = rendered.contains
            }
            if !model.moveSelectionInMap(move, extending: shift, isRendered: isRendered) {
                host.beep()
            }
        }
        return true
    }

    /// The maps' arrow keys: right goes deeper, left shallower, up and down to the previous or next sibling.
    static func treeMove(for vk: Int32) -> TreeKeyboardNav.Move? {
        switch vk {
        case VK_RIGHT: .child
        case VK_LEFT: .parent
        case VK_UP: .previous
        case VK_DOWN: .next
        default: nil
        }
    }

    private func statusText(for cell: TreemapCell) -> String {
        if cell.isFreeSpace {
            return AppStrings.format("Free space · %@", NeodiskFormatters.size(model.vizFreeSpaceBytes ?? 0))
        }
        if cell.isHiddenSpace {
            return AppStrings.format("Hidden space · %@", NeodiskFormatters.size(model.vizHiddenSpaceBytes ?? 0))
        }
        if let aggregate = cell.aggregate {
            return AppStrings.format(
                "%lld smaller items · %@", Int64(aggregate.itemCount), NeodiskFormatters.size(aggregate.totalSize))
        }
        guard let node = model.store?.node(id: cell.nodeID) else { return cell.nodeID }
        return "\(node.name) · \(NeodiskFormatters.size(node.allocatedSize)) · \(node.path)"
    }

    // MARK: - Benchmark access

    /// A point inside the n-th cell, for scripted hover.
    func benchmarkPoint(_ index: Int) -> CGPoint? {
        guard let frame, !frame.scene.cells.isEmpty else { return nil }
        let cell = frame.scene.cells[index % frame.scene.cells.count]
        return CGPoint(x: cell.rect.midX, y: cell.rect.midY)
    }

    var isRenderPending: Bool { inFlight != nil || currentInputs() != frame?.inputs }
}
