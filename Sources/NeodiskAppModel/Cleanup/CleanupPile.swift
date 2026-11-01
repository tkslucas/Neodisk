// The items collected for the Trash in one location's scan: top-level only (a folder absorbs what's inside it),
// in the order they were added. Pure, so both apps and the tests share it.

import Foundation
import NeodiskKit

package struct CleanupPile: Equatable, Sendable {
    package private(set) var itemIDs: [String] = []
    /// `itemIDs` as a set: membership is asked per list row and per ancestor.
    private var idSet: Set<String> = []
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
        idSet.contains(id)
    }

    /// The collected item that is `id` or holds it. O(depth).
    package func collectedItem(containing id: String, in store: FileTreeStore) -> String? {
        guard !idSet.isEmpty else { return nil }
        if idSet.contains(id) { return id }
        var cursor = store.parent(of: id)
        while let node = cursor {
            if idSet.contains(node.id) { return node.id }
            cursor = store.parent(of: node.id)
        }
        return nil
    }

    /// Adds the ids in `store`, in O((ids + pile) × depth): a folder replaces the collected items inside it, and an
    /// item inside a collected or added folder is already in. Returns the ids actually added.
    @discardableResult
    package mutating func add(_ ids: [String], in store: FileTreeStore) -> [String] {
        let candidates = ids.filter { collectedItem(containing: $0, in: store) == nil }
        let added = store.topLevelNodeIDs(from: candidates)
        guard !added.isEmpty else { return [] }
        let addedSet = Set(added)
        remove(Set(itemIDs.filter { store.hasAncestor(in: addedSet, of: $0) }))
        for id in added {
            guard let node = store.node(id: id) else { continue }
            itemIDs.append(id)
            idSet.insert(id)
            fingerprints[id] = Fingerprint(node)
        }
        return added
    }

    package mutating func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        itemIDs.removeAll { ids.contains($0) }
        idSet.subtract(ids)
        for id in ids { fingerprints[id] = nil }
    }

    package mutating func removeAll() {
        itemIDs.removeAll()
        idSet.removeAll()
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
    /// A selection split for the Trash: the outermost items that may go, and the reasons of the refused ones no
    /// allowed item holds. A refused folder (the scan root) doesn't take the items selected inside it down with it.
    func trashSplit<Reason>(_ nodes: [FileNodeRecord], reasons: [Reason?]) -> (allowed: [FileNodeRecord], refused: [Reason]) {
        let allowedIDs = zip(nodes, reasons).compactMap { $1 == nil ? $0.id : nil }
        let allowedSet = Set(allowedIDs)
        let refused = zip(nodes, reasons).compactMap { node, reason in
            hasAncestor(in: allowedSet, of: node.id) ? nil : reason
        }
        return (topLevelNodeIDs(from: allowedIDs).compactMap { node(id: $0) }, refused)
    }

    /// Where a view on `id` lands once `removedIDs` leave the tree: `id` itself, or the folder holding the outermost
    /// removed item above it. Nil for an unknown id.
    func survivor(of id: String, removing removedIDs: Set<String>) -> String? {
        guard node(id: id) != nil else { return nil }
        let chain = path(to: id)
        return chain[..<(chain.firstIndex { removedIDs.contains($0.id) } ?? chain.endIndex)].last?.id
    }
}
