// Layer-hosting view: a masksToBounds container keeps zoomed content off neighboring panes, and gestures
// set the layer transform directly with no SwiftUI round-trip, so zoom tracks the trackpad.

import AppKit
import TreemapKit
import NeodiskAppModel

final class TreemapNSView: NSView, NSDraggingSource {
    let controller: TreemapController

    /// Carries the image, labels, and selection in rendered-scene
    /// coordinates; the live viewport is applied as this layer's transform.
    private let contentLayer = CALayer()
    private let imageLayer = CALayer()
    private let labelContainerLayer = CALayer()
    /// One ring per selected item, all in one path.
    private let selectionLayer = CAShapeLayer()
    private let hoverLayer = CALayer()
    /// Cleanup marks: a wash over collected items and a hairline around them. Quiet on purpose: the map stays
    /// readable with a full pile.
    private let cleanupWashLayer = CAShapeLayer()
    private let cleanupOutlineLayer = CAShapeLayer()
    /// A press that may become a drag once it travels `dragThreshold`; its click may wait for mouse-up.
    private var pendingPress: PendingPress?
    private static let dragThreshold: CGFloat = 4

    private struct PendingPress {
        let start: CGPoint
        /// What a drag from here carries; empty when there is nothing to drag.
        let dragIDs: [String]
        /// The click that runs at mouse-up unless the press became a drag: a ⌘/⇧-click, or a press on the
        /// selection, which a drag must keep whole. Nil when the click already ran at mouse-down.
        let deferredClick: MapClick?
    }
    /// Identity of the scene whose labels are currently materialized.
    private var labeledSceneViewport: TreemapViewport?
    private let debugSnapshotter = DebugSnapshotter.shared

    init(controller: TreemapController) {
        self.controller = controller
        super.init(frame: .zero)
        controller.view = self

        // No background: the window server tints the real backdrop, and a painted windowBackgroundColor misses
        // that compositing and reads darker. Uncovered pixels stay transparent.
        let rootLayer = CALayer()
        rootLayer.masksToBounds = true
        rootLayer.isGeometryFlipped = true
        layer = rootLayer
        wantsLayer = true
        // Since macOS 14 clipsToBounds defaults to false and AppKit pushes it onto the layer, overriding
        // masksToBounds.
        clipsToBounds = true

        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        selectionLayer.strokeColor = NSColor.systemYellow.cgColor
        selectionLayer.fillColor = nil
        selectionLayer.isHidden = true
        hoverLayer.isHidden = true

        for layer in [cleanupWashLayer, cleanupOutlineLayer] {
            layer.isHidden = true
            layer.fillColor = nil
            layer.lineJoin = .round
        }

        contentLayer.addSublayer(imageLayer)
        // The labels' soft glow, one pass over all of them; each label draws its own tight edge.
        labelContainerLayer.shadowColor = NSColor.black.cgColor
        labelContainerLayer.shadowOpacity = Float(TreemapScene.labelGlowShadow.opacity)
        labelContainerLayer.shadowRadius = TreemapScene.labelGlowShadow.radius
        labelContainerLayer.shadowOffset = .zero
        contentLayer.addSublayer(labelContainerLayer)
        // Over the labels so a collected item's name dims with it; under hover and selection.
        contentLayer.addSublayer(cleanupWashLayer)
        contentLayer.addSublayer(cleanupOutlineLayer)
        // Hover under selection, so the selection ring stays on top when
        // both land on the same cell.
        contentLayer.addSublayer(hoverLayer)
        contentLayer.addSublayer(selectionLayer)
        rootLayer.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TreemapNSView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Display

    /// Applies the controller's current image, transform, labels, and
    /// selection to the layer tree in one transaction.
    func refreshDisplay(contentsChanged: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let scene = controller.scene, let image = controller.image else {
            imageLayer.contents = nil
            labelContainerLayer.sublayers = nil
            labeledSceneViewport = nil
            selectionLayer.isHidden = true
            hoverLayer.isHidden = true
            hideCleanupLayers()
            contentLayer.setAffineTransform(.identity)
            return
        }

        if contentsChanged {
            imageLayer.contents = image
            imageLayer.contentsScale = controller.renderedScale
            imageLayer.bounds = CGRect(origin: .zero, size: scene.renderBounds.size)
            imageLayer.position = scene.renderBounds.origin
        }

        let transform = controller.displayTransform
        contentLayer.setAffineTransform(transform)

        if labeledSceneViewport != scene.viewport || contentsChanged {
            rebuildLabels(for: scene)
            labeledSceneViewport = scene.viewport
        }

        placeSelection()
        refreshHoverLayer()
        refreshCleanupLayers()
    }

    /// Redraws only the Cleanup overlay; the marks themselves are memoized per scene and pile.
    func refreshCleanupLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let scene = controller.scene, controller.image != nil else {
            hideCleanupLayers()
            return
        }
        let marks = controller.cleanupMarks
        guard !marks.isEmpty else {
            hideCleanupLayers()
            return
        }
        // Strokes keep their on-screen width under the zoom transform, like the selection ring.
        let unit = 1 / max(controller.displayTransform.a, 0.001)
        let radius: CGFloat = scene.style == .flat ? 4 : 0
        let lineWidth = unit

        func path(_ rects: [CGRect], inset: CGFloat) -> CGPath {
            Self.ringPath(rects, inset: inset, radius: radius)
        }

        var colors = CleanupColors()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = CleanupColors(
                wash: NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor,
                outline: NSColor.labelColor.withAlphaComponent(0.35).cgColor
            )
        }

        cleanupWashLayer.path = marks.washesCanvas
            ? CGPath(rect: marks.canvas, transform: nil)
            : path(marks.collected + marks.moving, inset: 0)
        cleanupWashLayer.fillColor = colors.wash
        cleanupWashLayer.isHidden = false

        cleanupOutlineLayer.path = path(marks.collected + marks.moving, inset: lineWidth / 2)
        cleanupOutlineLayer.strokeColor = colors.outline
        cleanupOutlineLayer.lineWidth = lineWidth
        cleanupOutlineLayer.isHidden = false
    }

    private struct CleanupColors {
        var wash: CGColor = .clear
        var outline: CGColor = .clear
    }

    private func hideCleanupLayers() {
        for layer in [cleanupWashLayer, cleanupOutlineLayer] {
            layer.isHidden = true
        }
    }

    /// Repositions only the hover ring, so pointer moves never pay for the
    /// full display refresh (selection re-layout, label rebuild checks).
    func refreshHoverLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard controller.scene != nil, controller.image != nil else {
            hoverLayer.isHidden = true
            return
        }
        // Neutral tint plus border reads on every palette and both cell
        // surfaces: brighten in dark mode, darken in light.
        if isDarkAppearance {
            hoverLayer.backgroundColor = CGColor(gray: 1, alpha: 0.075)
            hoverLayer.borderColor = CGColor(gray: 1, alpha: 0.72)
        } else {
            hoverLayer.backgroundColor = CGColor(gray: 0, alpha: 0.055)
            hoverLayer.borderColor = CGColor(gray: 0, alpha: 0.58)
        }
        place(hoverLayer, over: controller.hoverRect, borderWidth: 1.75)
    }

    /// Rounded rects drawn inside `rects` (inset by `inset`), corners following the flat tiles' radius.
    static func ringPath(_ rects: [CGRect], inset: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for rect in rects {
            let inner = rect.insetBy(dx: inset, dy: inset)
            guard inner.width > 0, inner.height > 0 else { continue }
            let corner = min(max(radius - inset, 0), inner.width / 2, inner.height / 2)
            path.addRoundedRect(in: inner, cornerWidth: corner, cornerHeight: corner)
        }
        return path
    }

    /// Every selected item gets the ring one selected item always had: 2pt on screen whatever the zoom, drawn
    /// inside the item, never thinner than a 2pt item.
    private func placeSelection() {
        let rects = controller.selectionRects
        guard let scene = controller.scene, !rects.isEmpty else {
            selectionLayer.isHidden = true
            return
        }
        let width = 2 / max(controller.displayTransform.a, 0.001)
        let rings = rects.map { CGRect(x: $0.minX, y: $0.minY, width: max($0.width, 2), height: max($0.height, 2)) }
        selectionLayer.path = Self.ringPath(rings, inset: width / 2, radius: scene.style == .flat ? 4 : 0)
        selectionLayer.lineWidth = width
        selectionLayer.isHidden = false
    }

    /// Compensates the content transform so the border keeps its on-screen width; nil hides the layer.
    private func place(_ outline: CALayer, over rect: CGRect?, borderWidth: CGFloat) {
        guard let rect, let scene = controller.scene else {
            outline.isHidden = true
            return
        }
        outline.isHidden = false
        // Flat tiles draw rounded and inset; the ring follows the shape.
        outline.cornerRadius = scene.style == .flat ? 4 : 0
        outline.frame = CGRect(
            x: rect.minX, y: rect.minY,
            width: max(rect.width, 2), height: max(rect.height, 2)
        )
        outline.borderWidth = borderWidth / max(controller.displayTransform.a, 0.001)
    }

    private func rebuildLabels(for scene: TreemapScene) {
        labelContainerLayer.sublayers = nil
        guard !scene.labels.isEmpty else { return }

        // Uses the scale the scene was laid out for, so label gates and drawn text never disagree.
        let fontSize = 11 * scene.labelScale
        let fileFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let headerFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let backingScale = window?.backingScaleFactor ?? 2
        for label in scene.labels {
            guard let layer = Self.labelLayer(
                for: label,
                font: label.isHeader ? headerFont : fileFont,
                backingScale: backingScale
            ) else { continue }
            labelContainerLayer.addSublayer(layer)
        }
    }

    /// "A..." carries no information, so such labels are dropped. The scene's size gates are only a pre-filter.
    static let minUsefulTruncatedCharacters = 4

    /// CATextLayer draws nothing once a string overflows its bounds (through macOS 26), so the text is
    /// pre-ellipsized to the frame. White on every fill and appearance, with the scene's tight dark edge (the
    /// container adds the glow).
    static func labelLayer(
        for label: TreemapScene.CellLabel,
        font: NSFont,
        backingScale: CGFloat
    ) -> CATextLayer? {
        let inset: CGFloat = label.isHeader ? 0 : 4
        let width = max(label.rect.width - 2 * inset, 10)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let fitted = Self.endTruncated(label.text, attributes: attributes, width: width)
        if fitted != label.text, fitted.count - 1 < Self.minUsefulTruncatedCharacters {
            return nil
        }
        let textLayer = CATextLayer()
        textLayer.string = NSAttributedString(string: fitted, attributes: attributes)
        textLayer.alignmentMode = label.isHeader ? .left : .center
        textLayer.contentsScale = backingScale
        textLayer.shadowColor = NSColor.black.cgColor
        textLayer.shadowOpacity = Float(TreemapScene.labelEdgeShadow.opacity)
        textLayer.shadowRadius = TreemapScene.labelEdgeShadow.radius
        textLayer.shadowOffset = .zero

        let height = ceil(font.ascender - font.descender) + 2
        textLayer.frame = CGRect(
            x: label.rect.minX + inset,
            y: label.rect.midY - height / 2,
            width: width,
            height: height
        )
        return textLayer
    }

    /// Binary search over the kept character count; fit is monotonic in it.
    static func endTruncated(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        width: CGFloat
    ) -> String {
        func fits(_ candidate: String) -> Bool {
            NSAttributedString(string: candidate, attributes: attributes).size().width <= width
        }
        if fits(text) { return text }
        let ellipsis = "…"
        guard fits(ellipsis) else { return "" }

        let characters = Array(text)
        func candidate(keeping count: Int) -> String {
            String(characters.prefix(count)) + ellipsis
        }
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(candidate(keeping: mid)) { low = mid } else { high = mid - 1 }
        }
        return candidate(keeping: low)
    }

    /// Purely presentational: model values are already set, so an interrupted animation snaps to rest.
    /// Labels fade in alongside so text never visibly stretches.
    func animateDrill(from start: CGAffineTransform) {
        let duration: CFTimeInterval = 0.28
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)

        let morph = CABasicAnimation(keyPath: "transform")
        morph.fromValue = CATransform3DMakeAffineTransform(start)
        morph.toValue = CATransform3DMakeAffineTransform(controller.displayTransform)
        morph.duration = duration
        morph.timingFunction = timing
        contentLayer.add(morph, forKey: "drillMorph")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = timing
        labelContainerLayer.add(fade, forKey: "drillLabelFade")
    }

    // MARK: - Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller.setViewSize(newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Re-rasterize label text for the new display scale.
        labeledSceneViewport = nil
        refreshDisplay(contentsChanged: false)
        // And re-render the map itself at the new pixel density.
        controller.backingScaleChanged()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Flat fills composite against the window background: rebuild the map for the new appearance.
        labeledSceneViewport = nil
        refreshDisplay(contentsChanged: false)
        controller.appearanceChanged()
    }

    // MARK: - Events

    /// Key focus so a click on the map is enough for spacebar Quick Look —
    /// without this, space only works after focusing one of the lists.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            controller.quickLookSelection()
            return
        }
        if controller.handleKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        controller.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller.hoverEnded()
    }

    // The map has no press-and-drag gesture of its own (pan is scroll, zoom is pinch or ⌥-scroll), so a press
    // that travels past the threshold always drags the item out. A plain click on an unselected item selects on
    // mouse-down; ⌘/⇧-clicks and presses on the selection wait for mouse-up, so a drag never changes the selection.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingPress = nil
        if event.clickCount == 2 {
            // Style-dependent: cushion reveals in Finder, flat drills into
            // folders (see TreemapController.doubleClick).
            controller.doubleClick(at: point)
            return
        }
        let flags = event.modifierFlags
        let kind = MapClick(command: flags.contains(.command), shift: flags.contains(.shift))
        let candidate = controller.dragCandidate(at: point)
        let defers = kind == .toggle || candidate?.carriesSelection == true
        pendingPress = PendingPress(
            start: point, dragIDs: candidate?.nodeIDs ?? [], deferredClick: defers ? kind : nil
        )
        if !defers {
            controller.click(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pending = pendingPress, !pending.dragIDs.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pending.start.x, point.y - pending.start.y) >= Self.dragThreshold else { return }
        pendingPress = nil
        guard let model = controller.model else { return }
        let items = NodeDragSource.draggingItems(forNodeIDs: pending.dragIDs, model: model, at: pending.start)
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let pending = pendingPress, let click = pending.deferredClick {
            controller.click(at: pending.start, click)
        }
        pendingPress = nil
    }

    /// Edit > Select All (⌘A) on the map: everything the map is rooted at, one level down.
    override func selectAll(_ sender: Any?) {
        controller.model?.selectAllInMap()
    }

    // MARK: - Dragging source

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        NodeDragPayload.operationMask(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // The tooltip and hover ring would otherwise stay frozen under the drag image.
        controller.hoverEnded()
        if let model = controller.model { NodeDragSource.sessionDidBegin(model: model) }
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        if let model = controller.model { NodeDragSource.sessionDidEnd(model: model) }
    }

    override func magnify(with event: NSEvent) {
        if event.phase == .began {
            controller.beginMagnify()
        }
        controller.magnify(
            by: 1 + event.magnification,
            anchor: convert(event.locationInWindow, from: nil)
        )
        if event.phase == .ended || event.phase == .cancelled {
            controller.endMagnify()
        }
    }

    override func smartMagnify(with event: NSEvent) {
        controller.smartMagnify(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        // Mouse wheels report coarse line deltas; trackpads report points.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.option) {
            let factor = exp2(event.scrollingDeltaY * step / 200)
            controller.scrollZoom(
                by: factor,
                anchor: convert(event.locationInWindow, from: nil)
            )
            return
        }
        let delta = CGSize(
            width: event.scrollingDeltaX * step,
            height: event.scrollingDeltaY * step
        )
        if !controller.scroll(by: delta) {
            super.scrollWheel(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller.contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        debugSnapshotter.scheduleIfRequested(for: self)
    }
}
