//
//  PaneSplitter.swift
//  Neodisk
//
//  A draggable hairline divider between workspace panes, implemented in
//  AppKit so it gets OS-managed resize-cursor behavior and smooth drag deltas
//  that a SwiftUI onHover/NSCursor version cannot match.
//

import AppKit
import SwiftUI

/// A draggable hairline divider between workspace panes. `paneEdge` names the
/// side the resizable pane sits on and implies the divider's orientation:
/// `.leading`/`.trailing` divide side-by-side panes, `.top`/`.bottom` divide
/// stacked ones.
///
/// Implemented in AppKit: `resetCursorRects` gives OS-managed resize-cursor
/// behavior that SwiftUI's onHover + NSCursor cannot match (the neighboring
/// table views keep resetting the cursor through their own cursor rects), and
/// `mouseDragged` deltas resize smoothly without coordinate-space fights.
///
/// Drags accumulate into an unclamped session value and only the published
/// size is clamped, so after the pane pins at a bound the divider stays put
/// until the pointer travels back — matching native splitters. Double-click
/// restores `defaultSize`; arrow keys resize when the divider has focus.
struct PaneSplitter: NSViewRepresentable {
    @Binding var size: Double
    let range: ClosedRange<Double>
    let defaultSize: Double
    /// Which side of the divider the resizable pane sits on.
    let paneEdge: Edge

    final class Coordinator {
        /// The in-flight drag's accumulated size, before clamping.
        var unclampedSize: Double?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SplitterNSView {
        let view = SplitterNSView(orientation: orientation)
        let anchor = orientation == .column ? view.widthAnchor : view.heightAnchor
        anchor.constraint(equalToConstant: SplitterNSView.thickness).isActive = true
        return view
    }

    func updateNSView(_ view: SplitterNSView, context: Context) {
        let coordinator = context.coordinator
        view.onDragBegan = { [self] in
            coordinator.unclampedSize = size.clamped(to: range)
        }
        view.onDrag = { [self] rawDelta in
            guard let unclamped = coordinator.unclampedSize else { return }
            let next = unclamped + deltaSign * rawDelta
            coordinator.unclampedSize = next
            size = next.clamped(to: range)
        }
        view.onReset = { [self] in
            size = defaultSize.clamped(to: range)
        }
    }

    var orientation: SplitterNSView.Orientation {
        switch paneEdge {
        case .leading, .trailing: .column
        case .top, .bottom: .row
        }
    }

    /// Maps the raw AppKit delta (rightward/downward positive) onto the
    /// resizable pane's size.
    var deltaSign: Double {
        switch paneEdge {
        case .leading, .top: 1
        case .trailing, .bottom: -1
        }
    }
}

final class SplitterNSView: NSView {
    /// Full divider breadth — the hit target. Only the two-point highlight
    /// strip ever becomes visible.
    static let thickness: CGFloat = 8
    /// One arrow-key press resizes the pane by this much.
    static let keyboardStep: CGFloat = 16

    enum Orientation {
        /// Vertical hairline between side-by-side panes; drag reports deltaX.
        case column
        /// Horizontal hairline between stacked panes; drag reports deltaY.
        case row
    }

    /// Fires once per resize gesture (mouse down or arrow key), before its
    /// first `onDrag`, so the owner can snapshot the starting size.
    var onDragBegan: (() -> Void)?
    /// Raw AppKit delta along the divider's resize axis.
    var onDrag: ((CGFloat) -> Void)?
    /// Double-click: restore the pane's default size.
    var onReset: (() -> Void)?

    private let orientation: Orientation
    private var isPointerInside = false
    private var isDragging = false

    private var resizeCursor: NSCursor {
        orientation == .column ? .resizeLeftRight : .resizeUpDown
    }

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        // .inVisibleRect keeps the area glued to the bounds, so one tracking
        // area installed here lasts the view's whole life.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Cursor & hover

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The .activeInKeyWindow tracking area sends no mouseExited once the
        // window resigns key, which would freeze the hover highlight on.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: window
        )
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
        }
    }

    @objc private func windowDidResignKey() {
        isPointerInside = false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        resizeCursor.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        needsDisplay = true
    }

    // MARK: Mouse resize

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Dragging a divider in a background window should resize, not just
        // activate.
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        isDragging = true
        onDragBegan?()
        resizeCursor.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        resizeCursor.set()
        onDrag?(orientation == .column ? event.deltaX : event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keyboard resize

    override var acceptsFirstResponder: Bool {
        // Focusable so Tab reaches the keyboard-resize path, but a click
        // should drag — never focus, never draw the focus ring.
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: false
        default: true
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override func keyDown(with event: NSEvent) {
        let rawDelta: CGFloat
        switch (orientation, event.specialKey) {
        case (.column, .leftArrow), (.row, .upArrow):
            rawDelta = -Self.keyboardStep
        case (.column, .rightArrow), (.row, .downArrow):
            rawDelta = Self.keyboardStep
        default:
            super.keyDown(with: event)
            return
        }
        // Each press is its own one-step resize gesture.
        onDragBegan?()
        onDrag?(rawDelta)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func accessibilityLabel() -> String? {
        NSLocalizedString("Pane divider", comment: "Accessibility label for a draggable pane divider")
    }

    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        // A splitter between side-by-side panes is a vertical bar.
        orientation == .column ? .vertical : .horizontal
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        if orientation == .row {
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        } else {
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }

        guard isPointerInside || isDragging else { return }
        drawHighlight()
    }

    /// The colored line stays visually quiet at its ends, then eases toward
    /// the accent at center. The full `thickness` view remains the hit
    /// target; only this two-point strip becomes visible on hover or drag.
    private func drawHighlight() {
        let accent = NSColor.controlAccentColor
        let strength = isDragging ? 0.85 : 0.55
        let gradient = NSGradient(colors: [
            accent.withAlphaComponent(0),
            accent.withAlphaComponent(strength * 0.25),
            accent.withAlphaComponent(strength),
            accent.withAlphaComponent(strength * 0.25),
            accent.withAlphaComponent(0),
        ])
        let lineRect: NSRect
        if orientation == .row {
            lineRect = NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        } else {
            lineRect = NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        }
        gradient?.draw(in: lineRect, angle: orientation == .row ? 0 : 90)
    }
}
