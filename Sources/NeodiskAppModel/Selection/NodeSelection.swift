// What the user has selected: any number of items, one of them primary (the last one clicked or added). Features
// that need a single item (drilling, arrow keys, the breadcrumb, the status swatch) read the primary; actions read
// every item. Pure, so both apps and the tests share it.

import Foundation
import NeodiskKit

package struct NodeSelection: Equatable, Sendable {
    /// In the order they were added; lists add theirs in row order.
    package private(set) var ids: [String] = []
    private var members: Set<String> = []
    /// Always one of `ids`; nil exactly when nothing is selected.
    package private(set) var primaryID: String?
    /// Bumped by every change, so views and caches compare one number instead of the whole set.
    package private(set) var revision: UInt64 = 0

    package init() {}

    package init(_ ids: [String], primary: String? = nil) {
        replace(with: ids, primary: primary)
        revision = 0
    }

    package var isEmpty: Bool { ids.isEmpty }
    package var count: Int { ids.count }
    /// More than one item: single-item features step aside.
    package var isMultiple: Bool { ids.count > 1 }

    package func contains(_ id: String) -> Bool {
        members.contains(id)
    }

    // MARK: - Changing it

    /// A plain click: just this item, or nothing.
    package mutating func replace(with id: String?) {
        replace(with: id.map { [$0] } ?? [], primary: id)
    }

    /// Exactly these items. The primary is `primary` when it's one of them, else the last.
    package mutating func replace(with newIDs: [String], primary: String?) {
        var seen = Set<String>()
        let unique = newIDs.filter { seen.insert($0).inserted }
        let newPrimary = primary.flatMap { seen.contains($0) ? $0 : nil } ?? unique.last
        guard unique != ids || newPrimary != primaryID else { return }
        ids = unique
        members = seen
        primaryID = newPrimary
        revision &+= 1
    }

    /// ⌘-click: an item joins as the primary, or leaves (the last remaining item becomes primary).
    package mutating func toggle(_ id: String) {
        if members.contains(id) {
            remove([id])
        } else {
            add(id)
        }
    }

    /// Joins as the primary; already in, it just becomes the primary.
    package mutating func add(_ id: String) {
        if members.insert(id).inserted {
            ids.append(id)
        } else if primaryID == id {
            return
        }
        primaryID = id
        revision &+= 1
    }

    package mutating func remove(_ removed: Set<String>) {
        guard !removed.isDisjoint(with: members) else { return }
        ids.removeAll { removed.contains($0) }
        members.subtract(removed)
        if let primaryID, removed.contains(primaryID) {
            self.primaryID = ids.last
        }
        revision &+= 1
    }

    package mutating func clear() {
        replace(with: nil)
    }

    // MARK: - Lists

    /// A list reports its selected rows. A plain click or arrow key means exactly those rows; an extending
    /// gesture (⌘- or ⇧-click, Select All) keeps the items this list doesn't show, like collapsed rows or
    /// another list's picks.
    package mutating func applyList(
        selected listIDs: [String],
        primary: String?,
        extending: Bool,
        listShows: (String) -> Bool
    ) {
        guard extending else {
            replace(with: listIDs, primary: primary)
            return
        }
        let kept = ids.filter { !listShows($0) }
        replace(with: kept + listIDs, primary: primary)
    }

    // MARK: - Reading it

    /// What an action from a context menu applies to: the whole selection when the clicked item is in it, else
    /// only the clicked item (the macOS rule).
    package func targets(clicked id: String?) -> [String] {
        guard let id else { return ids }
        return members.contains(id) ? ids : [id]
    }

    /// Whether a folder holding `id` is selected too. O(depth).
    package func containsAncestor(of id: String, in store: FileTreeStore) -> Bool {
        guard ids.count > 1 else { return false }
        var cursor = store.parent(of: id)
        while let node = cursor {
            if members.contains(node.id) { return true }
            cursor = store.parent(of: node.id)
        }
        return false
    }

    /// Without the items inside another selected item: what sizes add up and what moves.
    package func topLevelIDs(in store: FileTreeStore) -> [String] {
        ids.count < 2 ? ids.filter { store.node(id: $0) != nil } : store.topLevelNodeIDs(from: ids)
    }

    package func nodes(in store: FileTreeStore) -> [FileNodeRecord] {
        ids.compactMap { store.node(id: $0) }
    }

    // MARK: - Tree changes

    /// After the tree changed under the same location: items keep their place by path, and what's gone leaves.
    /// Returns whether anything left.
    @discardableResult
    package mutating func reconcile(with store: FileTreeStore) -> Bool {
        let gone = ids.filter { store.node(id: $0) == nil }
        remove(Set(gone))
        return !gone.isEmpty
    }

    /// Before items leave the tree: what's inside them leaves the selection. Emptied, it lands on the folder that
    /// held the primary, so the keyboard keeps a place to start from.
    package mutating func prepareForRemoval(of removedIDs: Set<String>, in store: FileTreeStore) {
        guard !ids.isEmpty, !removedIDs.isEmpty else { return }
        let gone = Set(ids.filter { store.isNodeOrDescendant($0, of: removedIDs) })
        guard !gone.isEmpty else { return }
        let survivor = primaryID.flatMap { store.survivor(of: $0, removing: removedIDs) }
        remove(gone)
        if ids.isEmpty, let survivor {
            replace(with: survivor)
        }
    }
}
