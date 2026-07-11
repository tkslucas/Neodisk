//
//  SunburstKeyboardNav.swift
//  Neodisk
//
//  Pure keyboard-navigation resolution for the sunburst: maps an arrow
//  press to the node the selection should move to. Sibling order is the
//  tree's display order (largest first), which is also the chart's angular
//  order, and every move is restricted to nodes the chart actually rendered
//  — pooled "smaller items" and beyond-depth nodes are skipped so the
//  selection never goes invisible.
//

import NeodiskKit

enum SunburstKeyboardNav {
    enum Direction {
        /// ← counterclockwise to the previous (larger) sibling arc.
        case previousSibling
        /// → clockwise to the next (smaller) sibling arc.
        case nextSibling
        /// ↑ one ring inward to the enclosing folder.
        case parent
        /// ↓ one ring outward to the folder's largest child.
        case largestChild
    }

    /// The node an arrow press moves the selection to, or nil when there is
    /// nowhere to go (caller beeps). Without a usable selection — nothing
    /// selected, or the selected node has no rendered segment in the current
    /// chart — any direction anchors on the root's largest rendered child,
    /// mirroring the treemap's "no selection selects the largest tile".
    static func target(
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
