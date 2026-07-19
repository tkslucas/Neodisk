//
//  TreemapNSView.swift
//  Neodisk
//
//  Layer-hosting AppKit view for the cushion treemap. A CALayer tree shows
//  the rendered image, file labels, and the selection outline inside a
//  masksToBounds container, so zoomed content can never draw over
//  neighboring panes (CALayer clipping is unconditional, unlike SwiftUI's
//  .clipped() over transformed content). Gestures update the content layer's
//  transform directly — no SwiftUI state round-trip — which is what makes
//  zoom/pan track the trackpad.
//

import AppKit
import TreemapKit

final class TreemapNSView: NSView {
    let controller: TreemapController

    /// Carries the image, labels, and selection in rendered-scene
    /// coordinates; the live viewport is applied as this layer's transform.
    private let contentLayer = CALayer()
    private let imageLayer = CALayer()
    private let labelContainerLayer = CALayer()
    private let selectionLayer = CALayer()
    /// Identity of the scene whose labels are currently materialized.
    private var labeledSceneViewport: TreemapViewport?
    private let debugSnapshotter = DebugSnapshotter.shared

    init(controller: TreemapController) {
        self.controller = controller
        super.init(frame: .zero)
        controller.view = self

        // Layer-hosting (layer assigned before wantsLayer) so the layer tree
        // is fully ours; geometryFlipped gives it the same top-left origin
        // as the flipped view and the scene geometry.
        // No background: the layer and the raster's uncovered pixels stay
        // transparent, so the pane shows the real window backdrop through
        // the tile gaps — same surface the sunburst sits on. Painting
        // windowBackgroundColor here can never match: on screen the window
        // server tints the actual backdrop (desktop tinting), and a layer
        // color misses that compositing, reading darker than the app.
        let rootLayer = CALayer()
        rootLayer.masksToBounds = true
        rootLayer.isGeometryFlipped = true
        layer = rootLayer
        wantsLayer = true
        // Since macOS 14, NSView.clipsToBounds defaults to false and AppKit
        // pushes it onto the layer, silently overriding masksToBounds. The
        // overscanned, gesture-transformed content must never draw over
        // neighboring panes, so clip at the view level too.
        clipsToBounds = true

        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        selectionLayer.borderColor = NSColor.systemYellow.cgColor
        selectionLayer.isHidden = true

        contentLayer.addSublayer(imageLayer)
        contentLayer.addSublayer(labelContainerLayer)
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

        // Flat tiles draw rounded and inset; the ring follows the shape.
        selectionLayer.cornerRadius = scene.style == .flat ? 4 : 0
        if let rect = controller.selectionRect {
            selectionLayer.isHidden = false
            selectionLayer.frame = CGRect(
                x: rect.minX, y: rect.minY,
                width: max(rect.width, 2), height: max(rect.height, 2)
            )
            // Compensate the content transform so the outline stays hairline.
            selectionLayer.borderWidth = 2 / max(transform.a, 0.001)
        } else {
            selectionLayer.isHidden = true
        }
    }

    private func rebuildLabels(for scene: TreemapScene) {
        labelContainerLayer.sublayers = nil
        guard !scene.labels.isEmpty else { return }

        let fileFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        // Flat container headers: the folder name sits left-aligned in the
        // header strip, bolder than file labels so hierarchy reads at a
        // glance.
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
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

    /// A truncated label must keep at least this many name characters to be
    /// worth drawing: "A…" or a bare "…" is clutter carrying no information,
    /// so such labels are dropped entirely. The scene's size gates are only
    /// a cheap pre-filter; this is the exact, text-measured rule.
    static let minUsefulTruncatedCharacters = 4

    /// One label's text layer, or nil when the rect is too narrow for a
    /// useful name. CATextLayer's own truncation draws nothing at all once
    /// a string overflows its bounds (observed through macOS 26), so the
    /// text is pre-ellipsized to the frame instead and the layer never has
    /// to truncate.
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

    /// `text` end-ellipsized so it measures within `width`: the name's head
    /// survives with a trailing "…", degrading to a bare "…" in the
    /// narrowest rects. Binary search over the kept character count; fit is
    /// monotonic in it.
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

    /// Plays the flat-style drill morph on the freshly rendered content:
    /// transform animates from `start` (the drilled container's former
    /// footprint, or the pulled-back parent position) to rest; labels fade
    /// in alongside so text never visibly stretches. Purely presentational —
    /// the layer's model values were already set by refreshDisplay, so an
    /// interrupted animation just snaps to the correct resting state.
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            // Style-dependent: cushion reveals in Finder, flat drills into
            // folders (see TreemapController.doubleClick).
            controller.doubleClick(at: point)
        } else {
            controller.click(at: point)
        }
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
