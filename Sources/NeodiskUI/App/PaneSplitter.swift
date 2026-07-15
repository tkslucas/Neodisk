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

/// A draggable hairline divider between workspace panes. Implemented in
/// AppKit: `resetCursorRects` gives OS-managed resize-cursor behavior that
/// SwiftUI's onHover + NSCursor cannot match (the neighboring table views
/// keep resetting the cursor through their own cursor rects), and
/// `mouseDragged` deltas resize smoothly without coordinate-space fights.
struct PaneSplitter: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the splitter the resizable pane sits on.
    let edge: HorizontalEdge

    func makeNSView(context: Context) -> SplitterNSView {
        let view = SplitterNSView()
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

final class SplitterNSView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}
