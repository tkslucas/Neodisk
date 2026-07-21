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

/// A draggable hairline divider between side-by-side workspace panes.
/// Implemented in AppKit: `resetCursorRects` gives OS-managed resize-cursor
/// behavior that SwiftUI's onHover + NSCursor cannot match (the neighboring
/// table views keep resetting the cursor through their own cursor rects), and
/// `mouseDragged` deltas resize smoothly without coordinate-space fights.
struct PaneSplitter: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the splitter the resizable pane sits on.
    let edge: HorizontalEdge

    func makeNSView(context: Context) -> SplitterNSView {
        let view = SplitterNSView(betweenStackedPanes: false)
        view.widthAnchor.constraint(equalToConstant: 8).isActive = true
        return view
    }

    func updateNSView(_ view: SplitterNSView, context: Context) {
        view.onDrag = { deltaX in
            let delta = edge == .leading ? deltaX : -deltaX
            width = min(max(width + delta, range.lowerBound), range.upperBound)
        }
    }
}

/// The stacked counterpart: a horizontal hairline between vertically stacked
/// panes whose drag resizes the pane on `edge` (.bottom = the pane below).
struct RowSplitter: NSViewRepresentable {
    @Binding var height: Double
    let range: ClosedRange<Double>
    /// Which side of the splitter the resizable pane sits on.
    let edge: VerticalEdge

    func makeNSView(context: Context) -> SplitterNSView {
        let view = SplitterNSView(betweenStackedPanes: true)
        view.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return view
    }

    func updateNSView(_ view: SplitterNSView, context: Context) {
        view.onDrag = { deltaY in
            let delta = edge == .bottom ? -deltaY : deltaY
            height = min(max(height + delta, range.lowerBound), range.upperBound)
        }
    }
}

final class SplitterNSView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    /// True when the splitter lies between stacked panes: horizontal
    /// hairline, up-down cursor, drag reports deltaY.
    private let betweenStackedPanes: Bool
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isDragging = false

    private var resizeCursor: NSCursor {
        betweenStackedPanes ? .resizeUpDown : .resizeLeftRight
    }

    init(betweenStackedPanes: Bool) {
        self.betweenStackedPanes = betweenStackedPanes
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        resizeCursor.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        resizeCursor.set()
        onDrag?(betweenStackedPanes ? event.deltaY : event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        if betweenStackedPanes {
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        } else {
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }

        guard isPointerInside || isDragging else { return }
        drawHighlight()
    }

    /// The colored line stays visually quiet at its ends, then eases toward
    /// the accent at center. The full eight-point view remains the hit target;
    /// only this two-point strip becomes visible on hover or drag.
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
        if betweenStackedPanes {
            lineRect = NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        } else {
            lineRect = NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        }
        gradient?.draw(in: lineRect, angle: betweenStackedPanes ? 0 : 90)
    }
}
