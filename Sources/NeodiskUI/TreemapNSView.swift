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
    private let debugSnapshotter = DebugSnapshotter()

    init(controller: TreemapController) {
        self.controller = controller
        super.init(frame: .zero)
        controller.view = self

        // Layer-hosting (layer assigned before wantsLayer) so the layer tree
        // is fully ours; geometryFlipped gives it the same top-left origin
        // as the flipped view and the scene geometry.
        let rootLayer = CALayer()
        rootLayer.masksToBounds = true
        rootLayer.isGeometryFlipped = true
        rootLayer.backgroundColor = CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
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

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let backingScale = window?.backingScaleFactor ?? 2
        for label in scene.labels {
            let textLayer = CATextLayer()
            textLayer.string = NSAttributedString(
                string: label.text,
                attributes: [.font: font, .foregroundColor: NSColor.white]
            )
            textLayer.truncationMode = .middle
            textLayer.alignmentMode = .center
            textLayer.contentsScale = backingScale
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOpacity = 0.9
            textLayer.shadowRadius = 2
            textLayer.shadowOffset = .zero

            let height = ceil(font.ascender - font.descender) + 2
            textLayer.frame = CGRect(
                x: label.rect.minX + 4,
                y: label.rect.midY - height / 2,
                width: max(label.rect.width - 8, 10),
                height: height
            )
            labelContainerLayer.addSublayer(textLayer)
        }
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
            // Double-click reveals in Finder (never re-roots the view —
            // mouse navigation stays pinch/scroll; re-rooting is keyboard
            // drill, ⌘↓/⌘↑, see TreemapController.handleKey).
            controller.revealInFinder(at: point)
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
