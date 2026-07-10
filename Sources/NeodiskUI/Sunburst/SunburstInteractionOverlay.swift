//
//  SunburstInteractionOverlay.swift
//  Neodisk
//
//  AppKit event layer over the sunburst: tracking-area hover, click vs drag
//  disambiguation (3 pt threshold), pinch-to-drill (spread over an arc opens
//  that folder, squeeze goes up one level — DaisyDisk style), tooltips, and
//  the right-click context menu. Ported from Radix minus its drag-to-discard
//  support (Neodisk is read-only) and viewport zoom/pan (drilling replaced
//  it).
//

import AppKit
import SwiftUI

enum SunburstPinchDirection {
    /// Fingers spreading apart — drill into the arc under the cursor.
    case drillIn
    /// Fingers pinching together — go up to the parent folder.
    case drillOut
}

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onPinchDrill: (CGPoint, SunburstPinchDirection) -> Void
    let contextMenu: (CGPoint) -> NSMenu?
    let help: (CGPoint) -> String?

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InteractionView) {
        view.onHover = onHover
        view.onClick = onClick
        view.onPinchDrill = onPinchDrill
        view.contextMenu = contextMenu
        view.help = help
    }

    final class InteractionView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var onPinchDrill: (CGPoint, SunburstPinchDirection) -> Void = { _, _ in }
        var contextMenu: (CGPoint) -> NSMenu? = { _ in nil }
        var help: (CGPoint) -> String? = { _ in nil }

        private static let dragThreshold: CGFloat = 3
        /// Accumulated |magnification| that commits a drill; a full
        /// deliberate pinch sums to ~1, so this triggers well before the
        /// fingers finish without firing on trackpad noise.
        private static let pinchDrillThreshold: CGFloat = 0.25
        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var didDrag = false
        private var pinchMagnification: CGFloat = 0
        private var didPinchDrill = false

        override var isFlipped: Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            updatePointerFeedback(at: eventLocation(event))
        }

        override func mouseMoved(with event: NSEvent) {
            updatePointerFeedback(at: eventLocation(event))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
            toolTip = nil
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = eventLocation(event)
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownLocation, !didDrag else { return }
            didDrag = didExceedDragThreshold(from: mouseDownLocation, to: eventLocation(event))
        }

        override func mouseUp(with event: NSEvent) {
            if !didDrag {
                onClick(eventLocation(event), event.clickCount)
            }
            mouseDownLocation = nil
            didDrag = false
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            contextMenu(eventLocation(event))
        }

        /// One drill per pinch gesture: magnification accumulates from the
        /// gesture's start and the first threshold crossing commits (latched
        /// until the fingers lift), so a long pinch cannot tunnel through
        /// several levels at once.
        override func magnify(with event: NSEvent) {
            if event.phase == .began {
                pinchMagnification = 0
                didPinchDrill = false
            }

            pinchMagnification += event.magnification

            if event.phase == .ended || event.phase == .cancelled {
                pinchMagnification = 0
                didPinchDrill = false
                return
            }

            guard !didPinchDrill,
                  abs(pinchMagnification) >= Self.pinchDrillThreshold else { return }

            didPinchDrill = true
            onPinchDrill(
                eventLocation(event),
                pinchMagnification > 0 ? .drillIn : .drillOut
            )
        }

        private func updateHelp(at location: CGPoint) {
            toolTip = help(location)
        }

        private func updatePointerFeedback(at location: CGPoint) {
            onHover(location)
            updateHelp(at: location)
        }

        private func eventLocation(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func didExceedDragThreshold(from start: CGPoint, to end: CGPoint) -> Bool {
            let dx = end.x - start.x
            let dy = end.y - start.y
            return ((dx * dx) + (dy * dy)) >= (Self.dragThreshold * Self.dragThreshold)
        }
    }
}
