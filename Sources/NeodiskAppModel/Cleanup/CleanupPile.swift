// The items collected for the Trash in one location's scan: top-level only (a folder absorbs what's inside it),
// in the order they were added. Pure, so both apps and the tests share it.

import Foundation
import NeodiskKit

package struct CleanupPile: Equatable, Sendable {
    package private(set) var itemIDs: [String] = []
    /// What each item was when it was collected. Ids are paths, so after a rescan the same path may hold
    /// something else: that item leaves the pile instead of standing in for the one the user picked.
    private var fingerprints: [String: Fingerprint] = [:]

    private struct Fingerprint: Equatable, Sendable {
        let isDirectory: Bool
        let identity: FileIdentity?
        /// Files only: a folder's size changes with its contents and it's still the same folder.
        let fileSize: Int64?

        init(_ node: FileNodeRecord) {
            isDirectory = node.isDirectory
            identity = node.fileIdentity
            fileSize = node.isDirectory ? nil : node.logicalSize
        }

        func matches(_ node: FileNodeRecord) -> Bool {
            let current = Fingerprint(node)
            guard current.isDirectory == isDirectory, current.fileSize == fileSize else { return false }
            if let identity, let currentIdentity = current.identity {
                return identity == currentIdentity
            }
            return true
        }
    }

    package init() {}

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
        for id in ids {
            guard let node = store.node(id: id), collectedItem(containing: id, in: store) == nil else { continue }
            remove(Set(itemIDs.filter { store.isNodeOrDescendant($0, of: [id]) }))
            itemIDs.append(id)
            fingerprints[id] = Fingerprint(node)
            added.append(id)
        }
        return added
    }

    package mutating func remove(_ ids: Set<String>) {
        itemIDs.removeAll { ids.contains($0) }
        for id in ids { fingerprints[id] = nil }
    }

    package mutating func removeAll() {
        itemIDs.removeAll()
        fingerprints.removeAll()
    }

    /// After the tree changed (a rescan, an expansion, a move): drops what's gone or became something else,
    /// and re-collapses nesting. Returns how many items were dropped because they changed.
    @discardableResult
    package mutating func reconcile(with store: FileTreeStore) -> Int {
        let previous = itemIDs
        let previousFingerprints = fingerprints
        removeAll()
        var changed = 0
        var kept: [String] = []
        for id in previous {
            guard let node = store.node(id: id) else { continue }
            if let fingerprint = previousFingerprints[id], !fingerprint.matches(node) {
                changed += 1
                continue
            }
            kept.append(id)
        }
        add(kept, in: store)
        return changed
    }

    package func nodes(in store: FileTreeStore) -> [FileNodeRecord] {
        itemIDs.compactMap { store.node(id: $0) }
    }

    package func totalSize(in store: FileTreeStore) -> Int64 {
        nodes(in: store).reduce(0) { $0 &+ $1.allocatedSize }
    }
}

package extension FileTreeStore {
    /// Where a view on `id` lands once `removedIDs` leave the tree: `id` itself, or the folder holding the outermost
    /// removed item above it. Nil for an unknown id.
    func survivor(of id: String, removing removedIDs: Set<String>) -> String? {
        guard node(id: id) != nil else { return nil }
        let chain = path(to: id)
        return chain[..<(chain.firstIndex { removedIDs.contains($0.id) } ?? chain.endIndex)].last?.id
    }
}
