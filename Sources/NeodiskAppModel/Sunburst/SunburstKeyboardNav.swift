// Maps an arrow press to the next selection. Moves are restricted to rendered nodes (pooled and beyond-depth
// ones are skipped) so the selection never goes invisible.

import NeodiskKit

package enum SunburstKeyboardNav {
    package enum Direction {
        /// ← counterclockwise to the previous (larger) sibling arc.
        case previousSibling
        /// → clockwise to the next (smaller) sibling arc.
        case nextSibling
        /// ↑ one ring inward to the enclosing folder.
        case parent
        /// ↓ one ring outward to the folder's largest child.
        case largestChild
    }

    /// Nil means nowhere to go (caller beeps). Without a rendered selection, any direction lands on the root's
    /// largest rendered child.
    package static func target(
        from selectedNodeID: String?,
        direction: Direction,
        rootID: String,
        store: FileTreeStore,
        isRendered: (String) -> Bool
    ) -> String? {
        guard let selectedNodeID,
              selectedNodeID != rootID,
              store.node(id: selectedNodeID) != nil,
              isRendered(selectedNodeID) else {
            return largestRenderedChild(of: rootID, store: store, isRendered: isRendered)
        }

        switch direction {
        case .parent:
            // Depth-1 arcs surround the center hole, which represents the
            // root itself and is not a selectable segment.
            guard let parent = store.parent(of: selectedNodeID), parent.id != rootID else {
                return nil
            }
            return parent.id
        case .largestChild:
            return largestRenderedChild(of: selectedNodeID, store: store, isRendered: isRendered)
        case .previousSibling, .nextSibling:
            guard let parentID = store.parent(of: selectedNodeID)?.id else { return nil }
            let siblings = store.children(of: parentID).filter { isRendered($0.id) }
            guard let index = siblings.firstIndex(where: { $0.id == selectedNodeID }) else {
                return nil
            }
            let next = direction == .nextSibling ? index + 1 : index - 1
            guard siblings.indices.contains(next) else { return nil }
            return siblings[next].id
        }
    }

    /// Display order is largest first, so the first rendered child with any
    /// size is the largest one.
    private static func largestRenderedChild(
        of nodeID: String,
        store: FileTreeStore,
        isRendered: (String) -> Bool
    ) -> String? {
        store.children(of: nodeID).first { $0.allocatedSize > 0 && isRendered($0.id) }?.id
    }
}
