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
    private let selectionLayer = CALayer()
    private let hoverLayer = CALayer()
    /// Cleanup marks: a wash over collected items, then a halo and a dashed (or, while moving, solid) outline.
    private let cleanupWashLayer = CAShapeLayer()
    private let cleanupHaloLayer = CAShapeLayer()
    private let cleanupOutlineLayer = CAShapeLayer()
    private let cleanupMovingLayer = CAShapeLayer()
    /// A press that may become a drag once it travels `dragThreshold`.
    private var pendingDrag: PendingDrag?
    private static let dragThreshold: CGFloat = 4

    private struct PendingDrag {
        let start: CGPoint
        let nodeID: String
        /// The press landed inside the selected folder: its click waits for mouse-up (see dragCandidate).
        let defersClick: Bool
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
        selectionLayer.borderColor = NSColor.systemYellow.cgColor
        selectionLayer.isHidden = true
        hoverLayer.isHidden = true

        for layer in [cleanupWashLayer, cleanupHaloLayer, cleanupOutlineLayer, cleanupMovingLayer] {
            layer.isHidden = true
            layer.fillColor = nil
            layer.lineJoin = .round
        }

        contentLayer.addSublayer(imageLayer)
        contentLayer.addSublayer(labelContainerLayer)
        // Over the labels so a collected item's name dims with it; under hover and selection.
        contentLayer.addSublayer(cleanupWashLayer)
        contentLayer.addSublayer(cleanupHaloLayer)
        contentLayer.addSublayer(cleanupOutlineLayer)
        contentLayer.addSublayer(cleanupMovingLayer)
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

        place(selectionLayer, over: controller.selectionRect, borderWidth: 2)
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
        let lineWidth = 2 * unit

        func path(_ rects: [CGRect], inset: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for rect in rects {
                let inner = rect.insetBy(dx: inset, dy: inset)
                guard inner.width > 0, inner.height > 0 else { continue }
                let corner = min(max(radius - inset, 0), inner.width / 2, inner.height / 2)
                path.addRoundedRect(in: inner, cornerWidth: corner, cornerHeight: corner)
            }
            return path
        }

        var colors = CleanupColors()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = CleanupColors(
                wash: NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor,
                halo: NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor,
                accent: NSColor.controlAccentColor.cgColor,
                moving: NSColor.secondaryLabelColor.cgColor
            )
        }

        cleanupWashLayer.path = marks.washesCanvas
            ? CGPath(rect: marks.canvas, transform: nil)
            : path(marks.collected + marks.moving, inset: 0)
        cleanupWashLayer.fillColor = colors.wash
        cleanupWashLayer.isHidden = false

        let outlined = path(marks.collected, inset: lineWidth / 2)
        cleanupHaloLayer.path = path(marks.collected + marks.moving, inset: lineWidth / 2)
        cleanupHaloLayer.strokeColor = colors.halo
        cleanupHaloLayer.lineWidth = lineWidth + unit
        cleanupHaloLayer.isHidden = false

        cleanupOutlineLayer.path = outlined
        cleanupOutlineLayer.strokeColor = colors.accent
        cleanupOutlineLayer.lineWidth = lineWidth
        cleanupOutlineLayer.lineDashPattern = [NSNumber(value: Double(5 * unit)), NSNumber(value: Double(3 * unit))]
        cleanupOutlineLayer.isHidden = marks.collected.isEmpty

        cleanupMovingLayer.path = path(marks.moving, inset: lineWidth / 2)
        cleanupMovingLayer.strokeColor = colors.moving
        cleanupMovingLayer.lineWidth = lineWidth
        cleanupMovingLayer.isHidden = marks.moving.isEmpty
    }

    private struct CleanupColors {
        var wash: CGColor = .clear
        var halo: CGColor = .clear
        var accent: CGColor = .clear
        var moving: CGColor = .clear
    }

    private func hideCleanupLayers() {
        for layer in [cleanupWashLayer, cleanupHaloLayer, cleanupOutlineLayer, cleanupMovingLayer] {
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
        // Both styles composite over the window background, so light mode
        // needs dark text (and no shadow); dark mode keeps white-on-shadow.
        let lightLabels = !isDarkAppearance
        let textColor: NSColor = lightLabels
            ? NSColor.black.withAlphaComponent(0.85) : .white
        for label in scene.labels {
            guard let layer = Self.labelLayer(
                for: label,
                font: label.isHeader ? headerFont : fileFont,
                textColor: textColor,
                shadowOpacity: lightLabels ? 0 : 0.9,
                backingScale: backingScale
            ) else { continue }
            labelContainerLayer.addSublayer(layer)
        }
    }

    /// "A..." carries no information, so such labels are dropped. The scene's size gates are only a pre-filter.
    static let minUsefulTruncatedCharacters = 4

    /// CATextLayer draws nothing once a string overflows its bounds (through macOS 26), so the text is
    /// pre-ellipsized to the frame.
    static func labelLayer(
        for label: TreemapScene.CellLabel,
        font: NSFont,
        textColor: NSColor,
        shadowOpacity: Float,
        backingScale: CGFloat
    ) -> CATextLayer? {
        let inset: CGFloat = label.isHeader ? 0 : 4
        let width = max(label.rect.width - 2 * inset, 10)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor,
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
        textLayer.shadowOpacity = shadowOpacity
        textLayer.shadowRadius = 2
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
        // Both styles composite against the window background and adapt
        // their label colors — rebuild both for the new appearance.
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
    // that travels past the threshold always drags the item out. A click still selects on mouse-down.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingDrag = nil
        if event.clickCount == 2 {
            // Style-dependent: cushion reveals in Finder, flat drills into
            // folders (see TreemapController.doubleClick).
            controller.doubleClick(at: point)
            return
        }
        let candidate = controller.dragCandidate(at: point)
        if let candidate {
            pendingDrag = PendingDrag(start: point, nodeID: candidate.nodeID, defersClick: candidate.isSelection)
        }
        if candidate?.isSelection != true {
            controller.click(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pending = pendingDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pending.start.x, point.y - pending.start.y) >= Self.dragThreshold else { return }
        pendingDrag = nil
        guard let model = controller.model,
              let item = NodeDragSource.draggingItem(forNodeID: pending.nodeID, model: model, at: pending.start)
        else { return }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let pending = pendingDrag, pending.defersClick {
            controller.click(at: pending.start)
        }
        pendingDrag = nil
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
