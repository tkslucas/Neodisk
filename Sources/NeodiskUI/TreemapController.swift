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

    /// Render-relevant inputs, compared as a unit so the flood of unrelated
    /// model updates (hover, selection, outline expansion) costs nothing.
    private struct Inputs: Equatable {
        var snapshotID: UUID?
        var rootID: String?
        var catalogID: UUID?
        var colorMode: TreemapColorMode = .kind
        var highlight: TreemapHighlight?
        var expandedAggregateIDs: Set<String> = []
        var freeSpaceBytes: Int64?
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

    // MARK: - Inputs from the representable

    func setInputs(
        snapshot: ScanSnapshot?,
        rootID: String?,
        catalog: FileKindCatalog,
        colorMode: TreemapColorMode = .kind,
        highlight: TreemapHighlight? = nil,
        expandedAggregateIDs: Set<String>,
        freeSpaceBytes: Int64? = nil
    ) {
        let newInputs = Inputs(
            snapshotID: snapshot?.id,
            rootID: rootID,
            catalogID: catalog.buildID,
            colorMode: colorMode,
            highlight: highlight,
            expandedAggregateIDs: expandedAggregateIDs,
            freeSpaceBytes: freeSpaceBytes
        )
        guard newInputs != inputs else { return }

        if newInputs.rootID != inputs.rootID || snapshot == nil {
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

    // MARK: - Events from the view

    func hover(at point: CGPoint) {
        guard let model else { return }
        let cell = cell(at: point)
        model.hoveredNodeID = cell?.nodeID
        model.hoveredAggregate = cell?.aggregate
        model.hoveredCellIsFreeSpace = cell?.isFreeSpace == true
    }

    func hoverEnded() {
        model?.hoveredNodeID = nil
        model?.hoveredAggregate = nil
        model?.hoveredCellIsFreeSpace = false
    }

    func click(at point: CGPoint) {
        guard let model else { return }
        guard let cell = cell(at: point) else {
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

    func revealInFinder(at point: CGPoint) {
        guard let model, let cell = cell(at: point),
              let node = model.store?.node(id: cell.nodeID),
              node.supportsFileActions else { return }
        model.select(cell.nodeID)
        model.reveal(node)
    }

    func beginMagnify() {
        gestureStartScale = viewport.scale
        gestureNetMagnification = 1
    }

    func magnify(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0 else { return }
        gestureNetMagnification *= factor
        viewport = viewport.zoomed(by: factor, anchor: anchor, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
    }

    func endMagnify() {
        // Pinching in while already at 1:1 steps out one folder.
        if gestureStartScale <= 1.001, viewport.scale <= 1.001, gestureNetMagnification < 0.9 {
            model?.zoomOut()
        }
        gestureNetMagnification = 1
        renderIfViewportMoved()
    }

    /// Option-scroll zoom (browser/maps style), anchored at the cursor.
    func scrollZoom(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0 else { return }
        viewport = viewport.zoomed(by: factor, anchor: anchor, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
    }

    /// Two-finger scroll pans the zoomed map. Returns false when the event
    /// should fall through to the responder chain (map at 1:1).
    func scroll(by delta: CGSize) -> Bool {
        guard viewport.scale > 1 else { return false }
        viewport = viewport.panned(by: delta, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
        return true
    }

    /// Two-finger double-tap: zoom the viewport in a comfortable step.
    func smartMagnify(at point: CGPoint) {
        viewport = viewport.zoomed(by: 2, anchor: point, viewSize: viewSize)
        pushDisplay()
        renderIfViewportMoved()
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let model, let cell = cell(at: point),
              let node = model.store?.node(id: cell.nodeID),
              node.supportsFileActions else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "Treemap context menu")) { model.reveal(node) })
        menu.addItem(ClosureMenuItem(title: NSLocalizedString("Open", comment: "Treemap context menu")) { model.open(node) })
        menu.addItem(ClosureMenuItem(title: NSLocalizedString("Copy Path", comment: "Treemap context menu")) { model.copyPath(node) })

        // Same subtree action as the outline's context menu: summarized
        // folders expand their contents in place.
        if node.isAutoSummarized {
            menu.addItem(.separator())
            let item = ClosureMenuItem(title: NSLocalizedString("Expand Contents", comment: "Treemap context menu")) { model.expandSummarizedNode(node) }
            item.isEnabled = model.canRefreshSubtree
            menu.addItem(item)
        }
        return menu
    }

    /// Spacebar Quick Look for the treemap: previews the selected node, so
    /// click-then-space works without ever focusing a sidebar list.
    func quickLookSelection() {
        guard let model, let node = model.selectedNode else {
            NSSound.beep()
            return
        }
        QuickLookPresenter.shared.togglePreview(for: node)
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
        let colorMode = inputs.colorMode
        let highlight = inputs.highlight
        let expandedAggregateIDs = inputs.expandedAggregateIDs
        let freeSpaceBytes = inputs.freeSpaceBytes
        let scale = view?.window?.backingScaleFactor ?? 2
        renderTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (TreemapScene, CGImage?) in
                let scene = TreemapScene.build(
                    store: store, rootID: rootID, size: size, catalog: catalog,
                    colorMode: colorMode,
                    highlight: highlight,
                    expandedAggregateIDs: expandedAggregateIDs,
                    viewport: viewport,
                    freeSpaceBytes: freeSpaceBytes
                )
                let image = CushionTreemapRenderer.render(cells: scene.cells, bounds: scene.renderBounds, scale: scale)
                return (scene, image)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.renderTask = nil
            self.scene = result.0
            self.image = result.1
            self.renderedScale = scale
            self.pushDisplay(contentsChanged: true)
            // The viewport may have moved on while this render was in
            // flight; chase it until display and viewport agree.
            self.renderIfViewportMoved()
        }
    }

    private func pushDisplay(contentsChanged: Bool = false) {
        view?.refreshDisplay(contentsChanged: contentsChanged)
    }
}

/// NSMenuItem that runs a closure; NSMenu's target/action plumbing needs an
/// object to point at, and the item itself is the natural owner.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem does not support NSCoder")
    }

    @objc private func invoke() {
        handler()
    }
}
