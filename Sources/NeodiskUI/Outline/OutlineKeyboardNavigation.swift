//
//  OutlineKeyboardNavigation.swift
//  Neodisk
//
//  Shared left/right hierarchy navigation for both flattened outline tables.
//  Resolution follows the displayed rows so parent/child moves honor the
//  bottom table's active sort and the Changes tab's diff ordering.
//

import AppKit

enum OutlineHierarchyDirection: Equatable {
    case left
    case right
}

enum OutlineHierarchyAction: Equatable {
    case expand(String)
    case collapse(String)
    case selectRow(Int)
}

@MainActor
enum OutlineKeyboardNavigation {
    static func action(
        for direction: OutlineHierarchyDirection,
        selectedRow: Int,
        rows: [NeodiskViewModel.OutlineRow],
        expandedNodeIDs: Set<String>
    ) -> OutlineHierarchyAction? {
        guard rows.indices.contains(selectedRow) else { return nil }
        let row = rows[selectedRow]
        let isExpanded = expandedNodeIDs.contains(row.id)

        switch direction {
        case .right:
            guard row.isExpandable else { return nil }
            if !isExpanded {
                return .expand(row.id)
            }
            let childRow = selectedRow + 1
            guard rows.indices.contains(childRow), rows[childRow].depth == row.depth + 1 else {
                return nil
            }
            return .selectRow(childRow)

        case .left:
            if row.isExpandable, isExpanded {
                return .collapse(row.id)
            }
            guard row.depth > 0 else { return nil }
            for parentRow in stride(from: selectedRow - 1, through: 0, by: -1) {
                if rows[parentRow].depth == row.depth - 1 {
                    return .selectRow(parentRow)
                }
            }
            return nil
        }
    }

    /// Returns the performed action so callers can reveal a `.selectRow`
    /// target that sits outside the viewport — unlike the built-in up/down
    /// arrows, a programmatic selection change never scrolls on its own.
    @discardableResult
    static func perform(
        _ direction: OutlineHierarchyDirection,
        in tableView: NSTableView,
        rows: [NeodiskViewModel.OutlineRow],
        model: NeodiskViewModel
    ) -> OutlineHierarchyAction? {
        guard let action = action(
            for: direction,
            selectedRow: tableView.selectedRow,
            rows: rows,
            expandedNodeIDs: model.expandedNodeIDs
        ) else { return nil }

        switch action {
        case .expand(let nodeID), .collapse(let nodeID):
            model.toggleExpansion(nodeID)
        case .selectRow(let row):
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            let nodeID = rows[row].id
            if model.selectedNodeID != nodeID {
                model.selectedNodeID = nodeID
            }
        }
        return action
    }
}
