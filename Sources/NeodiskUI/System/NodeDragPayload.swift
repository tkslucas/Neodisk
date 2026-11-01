// A drag of scanned items: a private payload Cleanup accepts (from the tree on screen only) and the file URL.
// Outside the app it only copies: a move behind the scan's back would leave the map wrong.

import AppKit
import NeodiskKit

extension NSPasteboard.PasteboardType {
    static let neodiskNodes = NSPasteboard.PasteboardType("com.lucastakayasu.neodisk.nodes")
}

struct NodeDragPayload: Codable, Equatable {
    let snapshotID: UUID
    let nodeIDs: [String]

    /// One pasteboard item per node, each carrying its own payload and file URL.
    @MainActor
    static func pasteboardItem(for node: FileNodeRecord, snapshotID: UUID) -> NSPasteboardItem? {
        guard !node.isSynthetic else { return nil }
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(NodeDragPayload(snapshotID: snapshotID, nodeIDs: [node.id])) {
            item.setData(data, forType: .neodiskNodes)
        }
        item.setString(node.url.absoluteString, forType: .fileURL)
        return item
    }

    /// Every node id on the pasteboard, or nil unless all of them came from `snapshotID`.
    static func nodeIDs(on pasteboard: NSPasteboard, snapshotID: UUID?) -> [String]? {
        guard let snapshotID, let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var ids: [String] = []
        for item in items {
            guard let data = item.data(forType: .neodiskNodes),
                  let payload = try? JSONDecoder().decode(NodeDragPayload.self, from: data),
                  payload.snapshotID == snapshotID else { return nil }
            ids += payload.nodeIDs
        }
        return ids
    }

    /// The operations a drag of scanned items offers: a copy outside the app, a collect inside it.
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
