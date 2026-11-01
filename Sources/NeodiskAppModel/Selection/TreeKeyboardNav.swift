// Arrow keys in the maps walk the tree: → largest child, ← parent, ↑↓ siblings in display order (largest first).
// Only items the view drew are reachable, so the selection never lands somewhere the map doesn't show.

import NeodiskKit
import TreemapKit

package enum TreeKeyboardNav {
    package enum Move: Sendable { case child, parent, previous, next }

    package enum Target: Equatable, Sendable {
        case select(String)
        /// ← on a top-level item while drilled: drill out one level, then select the folder the map showed.
        case drillOut(selecting: String)
    }

    /// Nil means nowhere to go (the caller beeps). With no selection, or one outside the map's root, any arrow
    /// picks the largest top-level item; an undrawn selection comes back to its nearest drawn ancestor.
    package static func target(
        from selectedID: String?,
        move: Move,
        rootID: String,
        store: FileTreeStore,
        isRendered: (String) -> Bool
    ) -> Target? {
        guard let selectedID, selectedID != rootID,
              let anchor = renderedAncestorOrSelf(selectedID, rootID: rootID, store: store, isRendered: isRendered)
        else {
            return largestChild(of: rootID, store: store, isRendered: isRendered).map(Target.select)
        }
        if anchor != selectedID { return .select(anchor) }
        guard let parentID = store.parent(of: anchor)?.id else { return nil }

        switch move {
        case .child:
            return largestChild(of: anchor, store: store, isRendered: isRendered).map(Target.select)
        case .parent:
            if parentID != rootID { return .select(parentID) }
            return rootID == store.rootID ? nil : .drillOut(selecting: rootID)
        case .previous, .next:
            let siblings = store.children(of: parentID).filter { isRendered($0.id) }
            guard let index = siblings.firstIndex(where: { $0.id == anchor }) else { return nil }
            let next = move == .next ? index + 1 : index - 1
            return siblings.indices.contains(next) ? .select(siblings[next].id) : nil
        }
    }

    /// What a treemap scene drew: every cell's node (a "smaller items" cell stands for its folder) and their
    /// ancestors, since cushion tiles draw leaves only.
    package static func renderedIDs(in cells: [TreemapCell], store: FileTreeStore) -> Set<String> {
        var rendered = Set<String>()
        for cell in cells where !cell.isFreeSpace && !cell.isHiddenSpace {
            var id = cell.nodeID
            while rendered.insert(id).inserted, let parent = store.parent(of: id) { id = parent.id }
        }
        return rendered
    }

    /// Nil when the item isn't under the root (or nothing between them is drawn).
    private static func renderedAncestorOrSelf(
        _ id: String, rootID: String, store: FileTreeStore, isRendered: (String) -> Bool
    ) -> String? {
        var current = id
        var found: String?
        while current != rootID {
            if found == nil, isRendered(current) { found = current }
            guard let parent = store.parent(of: current) else { return nil }
            current = parent.id
        }
        return found
    }

    private static func largestChild(
        of id: String, store: FileTreeStore, isRendered: (String) -> Bool
    ) -> String? {
        store.children(of: id).first { isRendered($0.id) }?.id
    }
}
