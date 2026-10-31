// The items collected for the Trash in one location's scan: top-level only (a folder absorbs what's inside it),
// in the order they were added. Pure, so both apps and the tests share it.

import Foundation
import NeodiskKit

package struct CleanupPile: Equatable, Sendable {
    package private(set) var itemIDs: [String] = []

    package init(itemIDs: [String] = []) {
        self.itemIDs = itemIDs
    }

    package var isEmpty: Bool { itemIDs.isEmpty }

    package func contains(_ id: String) -> Bool {
        itemIDs.contains(id)
    }

    /// The collected item that is `id` or holds it.
    package func collectedItem(containing id: String, in store: FileTreeStore) -> String? {
        if itemIDs.contains(id) { return id }
        var cursor = store.parent(of: id)
        while let node = cursor {
            if itemIDs.contains(node.id) { return node.id }
            cursor = store.parent(of: node.id)
        }
        return nil
    }

    /// Adds the ids that exist in `store`. A folder replaces the collected items inside it; an item inside a
    /// collected folder is already in. Returns the ids actually added.
    @discardableResult
    package mutating func add(_ ids: [String], in store: FileTreeStore) -> [String] {
        var added: [String] = []
        for id in ids where store.node(id: id) != nil && collectedItem(containing: id, in: store) == nil {
            itemIDs.removeAll { store.isNodeOrDescendant($0, of: [id]) }
            itemIDs.append(id)
            added.append(id)
        }
        return added
    }

    package mutating func remove(_ ids: Set<String>) {
        itemIDs.removeAll { ids.contains($0) }
    }

    package mutating func removeAll() {
        itemIDs.removeAll()
    }

    /// After the tree changed (a rescan, an expansion, a move): drops what's gone and re-collapses nesting.
    package mutating func reconcile(with store: FileTreeStore) {
        let previous = itemIDs
        itemIDs = []
        add(previous, in: store)
    }

    package func nodes(in store: FileTreeStore) -> [FileNodeRecord] {
        itemIDs.compactMap { store.node(id: $0) }
    }

    package func totalSize(in store: FileTreeStore) -> Int64 {
        nodes(in: store).reduce(0) { $0 &+ $1.allocatedSize }
    }
}
