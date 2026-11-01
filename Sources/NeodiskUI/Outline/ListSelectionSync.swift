// Keeps one AppKit list and the model's selection in step, both ways: the model's items become selected rows
// (the primary last, so it anchors ⇧-click ranges), and a user's rows become the model's selection. Shared by
// the left outline, the bottom table and the statistics lists, so their reentrancy rules can't drift.

import AppKit
import NeodiskAppModel

@MainActor
final class ListSelectionSync {
    private var isApplying = false
    /// Set while the table reports a selection: syncing back mid-event is reentrant.
    private(set) var isReporting = false
    /// The primary the list last scrolled to: reveal again only when the model's primary changes, not on reloads.
    private var revealedPrimary: String?
    /// What was last mirrored. Copies of one selection share storage, so comparing them is cheap.
    private var applied: (selection: NodeSelection, rows: UInt64)?

    /// Changes the table makes while the model is being mirrored (selecting rows, reloading) aren't the user's.
    func whileApplying(_ body: () -> Void) {
        let wasApplying = isApplying
        isApplying = true
        body()
        isApplying = wasApplying
    }

    /// Model → table. `rowsVersion` changes whenever the rows do. Returns the primary's row when the list should
    /// scroll to it.
    func apply(
        _ selection: NodeSelection, rowsVersion: UInt64, to tableView: NSTableView, row: (String) -> Int?
    ) -> Int? {
        guard !isReporting else { return nil }
        // Mid-click the table shows the clicked row before the delegate fires; syncing now would revert it.
        if (tableView as? OutlineNSTableView)?.isTrackingClick == true { return nil }
        if let applied, applied.rows == rowsVersion, applied.selection == selection { return nil }
        applied = (selection, rowsVersion)

        var rows = IndexSet()
        for id in selection.ids {
            if let index = row(id) { rows.insert(index) }
        }
        let primaryRow = selection.primaryID.flatMap(row)
        if tableView.selectedRowIndexes != rows || (primaryRow.map { tableView.selectedRow != $0 } ?? false) {
            whileApplying {
                if let primaryRow {
                    var others = rows
                    others.remove(primaryRow)
                    tableView.selectRowIndexes(others, byExtendingSelection: false)
                    tableView.selectRowIndexes([primaryRow], byExtendingSelection: true)
                } else {
                    tableView.selectRowIndexes(rows, byExtendingSelection: false)
                }
            }
        }
        guard revealedPrimary != selection.primaryID else { return nil }
        revealedPrimary = selection.primaryID
        return primaryRow
    }

    /// Forgets what was mirrored, so the next `apply` runs even with the same revision (the rows were rebuilt).
    func invalidate() {
        applied = nil
    }

    /// Table → model, for a change the user made. Nil while the model is being mirrored.
    func userSelection(in tableView: NSTableView, id: (Int) -> String?) -> ListSelection? {
        guard !isApplying else { return nil }
        let ids = tableView.selectedRowIndexes.compactMap(id)
        let primary = tableView.selectedRow >= 0 ? id(tableView.selectedRow) : nil
        return ListSelection(ids: ids, primary: primary, extending: ListSelection.isExtendingGesture(in: tableView))
    }

    /// Runs the model update for a user's change; the model's echo back to this table is skipped.
    func report(_ selection: ListSelection, _ body: () -> Void) {
        revealedPrimary = selection.primary
        isReporting = true
        body()
        isReporting = false
        // The model may have taken less than the rows (an entry that's gone): mirror what it holds next time.
        applied = nil
    }
}

/// The rows a user selected in a list.
struct ListSelection: Equatable {
    let ids: [String]
    let primary: String?
    /// ⌘- or ⇧-click, ⇧-arrow: the items this list doesn't show stay selected. Select All isn't one: it picks
    /// exactly this list's rows, so ⌘⌫ after it never takes something picked in another view.
    let extending: Bool

    /// One row picked with a plain click or arrow key: the list's usual single-item action applies.
    var isSingle: Bool { !extending && ids.count == 1 }

    @MainActor
    static func isExtendingGesture(in tableView: NSTableView) -> Bool {
        if (tableView as? OutlineNSTableView)?.isSelectingAll == true { return false }
        guard let event = NSApp?.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown:
            return !event.modifierFlags.intersection([.command, .shift]).isEmpty
        default:
            return false
        }
    }
}
