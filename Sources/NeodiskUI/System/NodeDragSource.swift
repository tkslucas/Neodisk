// Starting a drag of scanned items from any view: which nodes may go, their pasteboard items, the one image
// every view drags, and the Cleanup panel's drop-target cue while a drag is under way.

import AppKit
import NeodiskKit

@MainActor
enum NodeDragSource {
    /// A real item of the tree on screen, outside a scan; synthetic blocks (free, hidden space) never drag.
    static func draggableNode(id: String, model: NeodiskViewModel) -> FileNodeRecord? {
        guard !model.coordinator.isScanning,
              let node = model.coordinator.snapshot?.treeStore.node(id: id),
              node.supportsFileActions else { return nil }
        return node
    }

    /// Nil too for a selected item inside another selected one: its folder carries it, so it isn't copied twice.
    static func pasteboardItem(forNodeID id: String, model: NeodiskViewModel) -> NSPasteboardItem? {
        if let store = model.store, model.selection.isMultiple, model.selection.contains(id),
           model.selection.containsAncestor(of: id, in: store) {
            return nil
        }
        guard let node = draggableNode(id: id, model: model),
              let snapshotID = model.coordinator.snapshot?.id else { return nil }
        return NodeDragPayload.pasteboardItem(for: node, snapshotID: snapshotID)
    }

    /// The dragging items for a map view: one image under the pointer (the other items travel without one).
    static func draggingItems(forNodeIDs ids: [String], model: NeodiskViewModel, at point: CGPoint) -> [NSDraggingItem] {
        let pairs = ids.compactMap { id -> (FileNodeRecord, NSPasteboardItem)? in
            guard let node = draggableNode(id: id, model: model),
                  let item = pasteboardItem(forNodeID: id, model: model) else { return nil }
            return (node, item)
        }
        guard let image = NodeDragImage.make(for: pairs.map(\.0)) else { return [] }
        let frame = NodeDragImage.frame(for: image, at: point)
        return pairs.enumerated().map { index, pair in
            let draggingItem = NSDraggingItem(pasteboardWriter: pair.1)
            draggingItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return draggingItem
        }
    }

    /// A list's drag gets the maps' image in place of the table's see-through snapshot of whole rows.
    static func tableSessionDidBegin(
        _ session: NSDraggingSession, in tableView: NSTableView, at screenPoint: NSPoint, model: NeodiskViewModel
    ) {
        sessionDidBegin(model: model)
        let ids = NodeDragPayload.nodeIDs(on: session.draggingPasteboard, snapshotID: model.coordinator.snapshot?.id)
        guard let window = tableView.window,
              let image = NodeDragImage.make(for: (ids ?? []).compactMap { draggableNode(id: $0, model: model) })
        else { return }
        let point = tableView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let frame = NodeDragImage.frame(for: image, at: point)
        session.draggingFormation = .none
        session.enumerateDraggingItems(
            options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, index, _ in
            item.setDraggingFrame(frame, contents: index == 0 ? image : nil)
        }
    }

    static func sessionDidBegin(model: NeodiskViewModel) {
        if !model.cleanup.isDragInProgress { model.cleanup.isDragInProgress = true }
    }

    static func sessionDidEnd(model: NeodiskViewModel) {
        if model.cleanup.isDragInProgress { model.cleanup.isDragInProgress = false }
    }
}

extension NSTableView {
    /// Rows drag their node out (a copy) or onto the Cleanup panel.
    func allowsNodeDrags() {
        setDraggingSourceOperationMask(NodeDragPayload.operationMask(for: .outsideApplication), forLocal: false)
        setDraggingSourceOperationMask(NodeDragPayload.operationMask(for: .withinApplication), forLocal: true)
    }
}

/// What every drag shows, as Finder does: the item's icon and name on a small card, or for several the stacked
/// icon and how many.
enum NodeDragImage {
    @MainActor
    static func make(for nodes: [FileNodeRecord]) -> NSImage? {
        guard let first = nodes.first else { return nil }
        if nodes.count == 1 {
            return make(title: first.name, icon: NSWorkspace.shared.icon(forFile: first.path))
        }
        return make(
            title: String(format: NSLocalizedString("%lld items", comment: "Drag image for several items"), nodes.count),
            icon: NSWorkspace.shared.icon(forFiles: nodes.map(\.path)) ?? NSWorkspace.shared.icon(forFile: first.path)
        )
    }

    /// Placed with the pointer on the icon, the name trailing it.
    static func frame(for image: NSImage, at point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - image.size.height / 2,
            y: point.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
    }

    @MainActor
    private static func make(title: String, icon: NSImage) -> NSImage {
        let scale = OutlineRowMetrics.scale
        let nameFont = NSFont.systemFont(ofSize: 12 * scale, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let name = title as NSString

        let iconSide = (18 * scale).rounded()
        let padding: CGFloat = 6
        let gap: CGFloat = 6
        let textHeight = ceil(nameFont.ascender - nameFont.descender)
        let nameWidth = min(ceil(name.size(withAttributes: nameAttributes).width), 240 * scale)
        let height = max(iconSide, textHeight) + 2 * padding
        let width = padding + iconSide + gap + nameWidth + 8

        return NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.lineWidth = 1
            card.stroke()

            icon.draw(in: CGRect(x: padding, y: (rect.height - iconSide) / 2, width: iconSide, height: iconSide))
            name.draw(
                with: CGRect(x: padding + iconSide + gap, y: (rect.height - textHeight) / 2, width: nameWidth, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: nameAttributes
            )
            return true
        }
    }
}
