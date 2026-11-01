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

    /// Nil means nowhere to go (the caller beeps). `isRendered` is nil while the view hasn't drawn this root yet
    /// (every item counts). `includingCloudOnly` orders siblings by the treemap's cloud-inclusive weight.
    package static func target(
        from selectedID: String?,
        move: Move,
        rootID: String,
        store: FileTreeStore,
        includingCloudOnly: Bool = false,
        isRendered: ((String) -> Bool)?
    ) -> Target? {
        Walk(
            rootID: rootID, store: store, includingCloudOnly: includingCloudOnly,
            isRendered: isRendered ?? { _ in true }
        ).target(from: selectedID, move: move)
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
}

private struct Walk {
    let rootID: String
    let store: FileTreeStore
    let includingCloudOnly: Bool
    let isRendered: (String) -> Bool

    /// No selection, or one outside the root: the largest top-level item. A pooled selection moves among its
    /// drawn siblings; one beyond depth comes back to its nearest drawn ancestor.
    func target(from selectedID: String?, move: TreeKeyboardNav.Move) -> TreeKeyboardNav.Target? {
        guard let selectedID, selectedID != rootID, let ancestors = ancestorsBelowRoot(of: selectedID) else {
            return largestChild(of: rootID).map { .select($0) }
        }
        let parentID = ancestors.first ?? rootID
        if !isRendered(selectedID), parentID != rootID, !isRendered(parentID) {
            return (ancestors.first(where: isRendered) ?? largestChild(of: rootID)).map { .select($0) }
        }

        switch move {
        case .child:
            return largestChild(of: selectedID).map { .select($0) }
        case .parent:
            if parentID != rootID { return .select(parentID) }
            return rootID == store.rootID ? nil : .drillOut(selecting: rootID)
        case .previous, .next:
            let siblings = orderedChildren(of: parentID)
            guard let index = siblings.firstIndex(of: selectedID) else { return nil }
            let target = move == .next
                ? siblings[(index + 1)...].first(where: isRendered)
                : siblings[..<index].last(where: isRendered)
            return target.map { .select($0) }
        }
    }

    /// Nearest first; nil when the item isn't under the root.
    private func ancestorsBelowRoot(of id: String) -> [String]? {
        var ancestors: [String] = []
        var current = id
        while let parent = store.parent(of: current)?.id {
            if parent == rootID { return ancestors }
            ancestors.append(parent)
            current = parent
        }
        return nil
    }

    private func orderedChildren(of id: String) -> [String] {
        TreemapScene.layoutSiblings(store.children(of: id), synthetic: [], includingCloudOnly: includingCloudOnly)
            .filter { $0.displayWeight(includingCloudOnly: includingCloudOnly) > 0 }
            .map(\.id)
    }

    private func largestChild(of id: String) -> String? {
        orderedChildren(of: id).first(where: isRendered)
    }
}
