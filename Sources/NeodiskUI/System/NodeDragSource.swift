// Starting a drag of scanned items from any view: which nodes may go, their pasteboard items, the image the
// map views drag, and the Cleanup panel's drop-target cue while a drag is under way.

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

    /// One dragging item for a map view, its image centered under the pointer.
    static func draggingItem(forNodeID id: String, model: NeodiskViewModel, at point: CGPoint) -> NSDraggingItem? {
        guard let node = draggableNode(id: id, model: model),
              let item = pasteboardItem(forNodeID: id, model: model) else { return nil }
        let image = NodeDragImage.make(for: node)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(
            CGRect(
                x: point.x - image.size.width / 2,
                y: point.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ),
            contents: image
        )
        return draggingItem
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

/// The tile a map drag shows: the item's icon, name and size on a small rounded card.
enum NodeDragImage {
    @MainActor
    static func make(for node: FileNodeRecord) -> NSImage {
        let scale = OutlineRowMetrics.scale
        let nameFont = NSFont.systemFont(ofSize: 12 * scale, weight: .medium)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let sizeAttributes: [NSAttributedString.Key: Any] = [
            .font: sizeFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let name = node.name as NSString
        let size = NeodiskFormatters.size(node.allocatedSize) as NSString

        let iconSide = (18 * scale).rounded()
        let padding: CGFloat = 8
        let gap: CGFloat = 6
        let nameWidth = min(ceil(name.size(withAttributes: nameAttributes).width), 240 * scale)
        let sizeWidth = ceil(size.size(withAttributes: sizeAttributes).width)
        let height = max(iconSide, ceil(nameFont.ascender - nameFont.descender)) + 2 * 6
        let width = padding + iconSide + gap + nameWidth + gap + sizeWidth + padding
        let icon = NSWorkspace.shared.icon(forFile: node.path)

        return NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.lineWidth = 1
            card.stroke()

            icon.draw(in: CGRect(x: padding, y: (rect.height - iconSide) / 2, width: iconSide, height: iconSide))
            let textHeight = ceil(nameFont.ascender - nameFont.descender)
            let textY = (rect.height - textHeight) / 2
            name.draw(
                with: CGRect(x: padding + iconSide + gap, y: textY, width: nameWidth, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: nameAttributes
            )
            let sizeHeight = ceil(sizeFont.ascender - sizeFont.descender)
            size.draw(
                at: CGPoint(x: rect.width - padding - sizeWidth, y: (rect.height - sizeHeight) / 2),
                withAttributes: sizeAttributes
            )
            return true
        }
    }
}
