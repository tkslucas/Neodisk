// AppKit event layer over the sunburst: hover, click vs drag (3 pt threshold), pinch-to-drill, tooltips, the
// context menu, and dragging an arc's item out or onto Cleanup. No viewport zoom (drilling replaced it).

import AppKit
import SwiftUI
import NeodiskAppModel

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Int) -> Void
    let onPinchDrill: (CGPoint, SunburstPinchDirection) -> Void
    /// Returns true when the key was handled (arrows, drill, space, Return);
    /// unhandled keys continue up the responder chain.
    let onKeyDown: (NSEvent) -> Bool
    let contextMenu: (CGPoint) -> NSMenu?
    let help: (CGPoint) -> String?
    /// The item a press at this point drags, or nil when there is nothing to drag there.
    var dragItem: (CGPoint) -> NSDraggingItem? = { _ in nil }
    var onDragSessionChange: (Bool) -> Void = { _ in }

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
        view.onKeyDown = onKeyDown
        view.contextMenu = contextMenu
        view.help = help
        view.dragItem = dragItem
        view.onDragSessionChange = onDragSessionChange
    }

    final class InteractionView: NSView, NSDraggingSource {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint, Int) -> Void = { _, _ in }
        var onPinchDrill: (CGPoint, SunburstPinchDirection) -> Void = { _, _ in }
        var onKeyDown: (NSEvent) -> Bool = { _ in false }
        var contextMenu: (CGPoint) -> NSMenu? = { _ in nil }
        var help: (CGPoint) -> String? = { _ in nil }
        var dragItem: (CGPoint) -> NSDraggingItem? = { _ in nil }
        var onDragSessionChange: (Bool) -> Void = { _ in }

        private static let dragThreshold: CGFloat = 3
        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var didDrag = false
        private var pinchRecognizer = PinchDrillRecognizer()

        override var isFlipped: Bool {
            true
        }

        /// Key focus so a click on the chart is enough for spacebar Quick
        /// Look and arrow navigation — same contract as TreemapNSView.
        override var acceptsFirstResponder: Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            if !onKeyDown(event) {
                super.keyDown(with: event)
            }
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

        /// Crossing the threshold turns the press into a drag of the arc it started on, if that arc has an item.
        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownLocation, !didDrag else { return }
            didDrag = didExceedDragThreshold(from: mouseDownLocation, to: eventLocation(event))
            guard didDrag, let item = dragItem(mouseDownLocation) else { return }
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(
            _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            NodeDragPayload.operationMask(for: context)
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            onHover(nil)
            toolTip = nil
            onDragSessionChange(true)
        }

        func draggingSession(
            _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
        ) {
            mouseDownLocation = nil
            didDrag = false
            onDragSessionChange(false)
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

        /// The first threshold crossing latches until the fingers lift, so a long pinch can't tunnel levels.
        override func magnify(with event: NSEvent) {
            if event.phase == .began {
                pinchRecognizer.begin()
            }

            if event.phase == .ended || event.phase == .cancelled {
                pinchRecognizer.end()
                return
            }

            if let direction = pinchRecognizer.accumulate(event.magnification) {
                onPinchDrill(eventLocation(event), direction)
            }
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
