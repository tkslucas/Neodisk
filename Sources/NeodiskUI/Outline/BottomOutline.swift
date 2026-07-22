//
//  BottomOutline.swift
//  Neodisk
//
//  The wide, multi-column file list shown below the treemap when the
//  outline docks at the bottom: name, subtree-percentage bar, size, file
//  count, and modified date, with sortable column headers. Consumes the
//  same flattened rows, expansion state, and selection as the left column,
//  so treemap auto-reveal, search, and file actions behave identically —
//  only the rendering differs.
//

import AppKit
import SwiftUI
import NeodiskKit

// MARK: - Pane

/// Search field on top (shared with the left layout), the multi-column
/// table underneath; search results replace the table exactly like they
/// replace the left column's tree.
struct BottomOutlinePane: View {
    let model: NeodiskViewModel

    var body: some View {
        VStack(spacing: 0) {
            OutlineSearchField(model: model)
            Divider()
            if let results = model.search.results {
                OutlineSearchResultsList(model: model, results: results)
            } else {
                let snapshot = model.outlineRowsSnapshot(sortedBy: model.outlineSort)
                BottomOutlineTable(
                    model: model,
                    snapshot: snapshot,
                    selectedID: model.selectedNodeID,
                    sort: model.outlineSort
                )
            }
        }
    }
}

// MARK: - Table

/// Multi-column view-based NSTableView over the flattened outline rows.
/// AppKit rather than SwiftUI Table for the same reasons as the left
/// column: reliable programmatic scroll-to-row for treemap auto-reveal,
/// mid-click reload protection, and row recycling that holds up on huge
/// expanded trees. Header sorts persist through AppPreferences and reorder
/// siblings in the model's flattening, never the store.
struct BottomOutlineTable: NSViewRepresentable {
    let model: NeodiskViewModel
    let snapshot: NeodiskViewModel.OutlineRowsSnapshot
    let selectedID: String?
    let sort: OutlineSort

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OutlineNSTableView()
        tableView.quickLookRequested = { [weak coordinator] in
            coordinator?.toggleQuickLook() ?? false
        }
        tableView.hierarchyNavigationRequested = { [weak coordinator] direction in
            coordinator?.navigateHierarchy(direction)
        }
        tableView.clickTrackingEnded = { [weak coordinator] in
            coordinator?.resyncSelectionAfterClick()
        }
        tableView.rowHeight = OutlineRowMetrics.rowHeight
        tableView.backgroundColor = .controlBackgroundColor
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for spec in Self.columns {
            let column = NSTableColumn(identifier: .init(spec.identifier))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.resizingMask = spec.identifier == "name"
                ? [.autoresizingMask, .userResizingMask]
                : .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.sortField.rawValue,
                ascending: spec.sortField == .name
            )
            if spec.alignsTrailing {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        tableView.sortDescriptors = [
            NSSortDescriptor(key: sort.field.rawValue, ascending: sort.ascending)
        ]

        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.didDoubleClick)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(snapshot: snapshot)
        coordinator.applySortIndicator(sort)
        coordinator.syncSelection(to: selectedID)
    }

    private struct ColumnSpec {
        let identifier: String
        let title: String
        let width: CGFloat
        let minWidth: CGFloat
        let sortField: OutlineSortField
        let alignsTrailing: Bool
    }

    /// The percentage column sorts by size: the bar is the size relative to
    /// the parent, so a separate order would only shuffle equal information.
    private static let columns: [ColumnSpec] = [
        ColumnSpec(
            identifier: "name",
            title: NSLocalizedString("Name", comment: "Bottom outline column header"),
            width: 320, minWidth: 160, sortField: .name, alignsTrailing: false
        ),
        ColumnSpec(
            identifier: "percent",
            title: NSLocalizedString("%", comment: "Bottom outline column header: subtree percentage"),
            width: 110, minWidth: 70, sortField: .size, alignsTrailing: false
        ),
        ColumnSpec(
            identifier: "size",
            title: NSLocalizedString("Size", comment: "Bottom outline column header"),
            width: 110, minWidth: 80, sortField: .size, alignsTrailing: true
        ),
        ColumnSpec(
            identifier: "files",
            title: NSLocalizedString("Files", comment: "Bottom outline column header: descendant file count"),
            width: 80, minWidth: 60, sortField: .files, alignsTrailing: true
        ),
        ColumnSpec(
            identifier: "modified",
            title: NSLocalizedString("Modified", comment: "Bottom outline column header"),
            width: 120, minWidth: 90, sortField: .modified, alignsTrailing: true
        ),
    ]

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private let model: NeodiskViewModel
        private(set) var rows: [NeodiskViewModel.OutlineRow] = []
        private var rowIndexByID: [String: Int] = [:]
        private var appliedStructuralVersion: UInt64?
        private var isProgrammaticSelection = false
        private(set) var structuralApplyCount = 0
        /// The selection the table last scrolled to: reveal again only when
        /// the model's selection actually changes, not on reloads.
        private var lastRevealedID: String?
        /// Structural rows that arrived while a click was being tracked;
        /// applied when the click finishes.
        private var pendingApply: NeodiskViewModel.OutlineRowsSnapshot?

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        init(model: NeodiskViewModel) {
            self.model = model
        }

        func apply(snapshot: NeodiskViewModel.OutlineRowsSnapshot) {
            guard snapshot.structuralVersion != appliedStructuralVersion else { return }
            // Mid-click, reloading would clear the row the user is holding
            // the mouse on; keep the table frozen until tracking ends.
            if let outlineTable = tableView as? OutlineNSTableView,
               outlineTable.isTrackingClick {
                pendingApply = snapshot
                return
            }
            pendingApply = nil
            appliedStructuralVersion = snapshot.structuralVersion
            rows = snapshot.rows
            rowIndexByID = snapshot.rowIndexByID
            structuralApplyCount += 1
            tableView?.reloadData()
        }

        /// Reflect the persisted sort into the header arrows. Guarded by
        /// equality so the resulting delegate callback writes nothing new.
        func applySortIndicator(_ sort: OutlineSort) {
            guard let tableView else { return }
            let current = tableView.sortDescriptors.first
            guard current?.key != sort.field.rawValue || current?.ascending != sort.ascending
            else { return }
            tableView.sortDescriptors = [
                NSSortDescriptor(key: sort.field.rawValue, ascending: sort.ascending)
            ]
        }

        func syncSelection(to selectedID: String?) {
            guard let tableView else { return }
            if let outlineTable = tableView as? OutlineNSTableView,
               outlineTable.isTrackingClick {
                return
            }
            let targetRow = selectedID.flatMap { rowIndexByID[$0] }
            if let targetRow {
                if tableView.selectedRow != targetRow {
                    isProgrammaticSelection = true
                    tableView.selectRowIndexes([targetRow], byExtendingSelection: false)
                    isProgrammaticSelection = false
                }
                if lastRevealedID != selectedID {
                    lastRevealedID = selectedID
                    scrollToRowVerticalOnly(targetRow)
                }
            } else {
                if selectedID == nil, tableView.selectedRow >= 0 {
                    isProgrammaticSelection = true
                    tableView.deselectAll(nil)
                    isProgrammaticSelection = false
                }
                lastRevealedID = selectedID
            }
        }

        func resyncSelectionAfterClick() {
            if let pendingApply {
                apply(snapshot: pendingApply)
            }
            syncSelection(to: model.selectedNodeID)
        }

        /// Vertical-only reveal: never disturbs an intentional horizontal
        /// position when the columns overflow a narrow pane.
        private func scrollToRowVerticalOnly(_ row: Int) {
            guard let tableView, let scrollView else { return }
            scrollOutlineRowVertically(
                tableView.rect(ofRow: row),
                in: scrollView,
                topOcclusion: tableView.headerView?.frame.height ?? 0
            )
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard row < rows.count, let tableColumn else { return nil }
            let outlineRow = rows[row]
            switch tableColumn.identifier.rawValue {
            case "name":
                return hostedCell(tableView, reuse: "name") { state in
                    OutlineNameSection(
                        model: model, row: outlineRow, state: state, truncatesName: true
                    )
                }
            case "percent":
                return hostedCell(tableView, reuse: "percent") { state in
                    SubtreePercentCell(fraction: outlineRow.fractionOfParent, state: state)
                }
            case "size":
                return hostedCell(tableView, reuse: "size") { state in
                    OutlineTrailingSection(
                        model: model, row: outlineRow, state: state,
                        trailingPadding: BottomOutlineMetrics.cellPadding
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case "files":
                let files = outlineRow.node.isDirectory
                    ? outlineRow.node.descendantFileCount.formatted()
                    : ""
                return hostedCell(tableView, reuse: "files") { state in
                    BottomDetailText(text: files, state: state)
                }
            case "modified":
                let modified = outlineRow.node.lastModified?
                    .formatted(date: .abbreviated, time: .omitted) ?? ""
                return hostedCell(tableView, reuse: "modified") { state in
                    BottomDetailText(text: modified, state: state)
                }
            default:
                return nil
            }
        }

        private func hostedCell<Content: View>(
            _ tableView: NSTableView,
            reuse identifier: String,
            content: (OutlineRowSelectionState) -> Content
        ) -> NSView {
            let reuseID = NSUserInterfaceItemIdentifier("bottom-" + identifier)
            let cell: BottomCellView<Content>
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: nil)
                as? BottomCellView<Content> {
                cell = reused
            } else {
                cell = BottomCellView<Content>()
                cell.identifier = reuseID
            }
            cell.host.rootView = content(cell.selectionState)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("BottomOutlineRow")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? BottomRowView {
                return reused
            }
            let rowView = BottomRowView()
            rowView.identifier = identifier
            return rowView
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticSelection, let tableView else { return }
            let row = tableView.selectedRow
            let newID = (row >= 0 && row < rows.count) ? rows[row].id : nil
            if model.selectedNodeID != newID {
                lastRevealedID = newID
                model.selectedNodeID = newID
            }
        }

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let field = OutlineSortField(rawValue: key) else { return }
            let sort = OutlineSort(field: field, ascending: descriptor.ascending)
            if let preferences = model.preferences, preferences.outlineSort != sort {
                preferences.outlineSort = sort
            }
        }

        // MARK: Row actions (parity with `fileNodeActions`)

        @objc func didDoubleClick(_ sender: Any?) {
            guard let tableView,
                  case let row = tableView.clickedRow, row >= 0, row < rows.count else { return }
            let node = rows[row].node
            guard model.supportsFileActions(node) else { return }
            model.select(node.id)
            model.reveal(node)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView,
                  case let row = tableView.clickedRow, row >= 0, row < rows.count else { return }
            let node = rows[row].node
            guard model.supportsFileActions(node) else { return }
            menu.addFileNodeActionItems(for: node, model: model)
        }

        func toggleQuickLook() -> Bool {
            guard let node = model.selectedNode else { return false }
            QuickLookPresenter.shared.togglePreview(for: node)
            return true
        }

        func navigateHierarchy(_ direction: OutlineHierarchyDirection) {
            guard let tableView else { return }
            let performed = OutlineKeyboardNavigation.perform(
                direction, in: tableView, rows: rows, model: model
            )
            if case .selectRow(let row) = performed {
                scrollToRowVerticalOnly(row)
            }
        }
    }
}

enum BottomOutlineMetrics {
    /// Horizontal breathing room inside detail cells; far tighter than the
    /// left pane's 16pt edge inset because columns provide the structure.
    static let cellPadding: CGFloat = 4
}

// MARK: - Cells

/// Percentage-of-parent bar plus label — the column that makes the wide
/// layout more than a rearranged left pane.
private struct SubtreePercentCell: View {
    let fraction: Double
    let state: OutlineRowSelectionState

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(state.showsAccentSelection
                            ? AnyShapeStyle(.white.opacity(0.25))
                            : AnyShapeStyle(.quaternary))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(state.showsAccentSelection
                            ? AnyShapeStyle(.white.opacity(0.9))
                            : AnyShapeStyle(Color.accentColor.opacity(0.65)))
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 5)

            Text(percentText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white.opacity(0.85))
                    : AnyShapeStyle(.secondary))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, BottomOutlineMetrics.cellPadding)
        .frame(maxHeight: .infinity)
    }

    private var percentText: String {
        if fraction >= 0.995 { return "100%" }
        if fraction > 0, fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

/// Right-aligned secondary detail text (file count, modified date).
private struct BottomDetailText: View {
    let text: String
    let state: OutlineRowSelectionState

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(state.showsAccentSelection
                ? AnyShapeStyle(.white.opacity(0.85))
                : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.horizontal, BottomOutlineMetrics.cellPadding)
    }
}

// MARK: - AppKit cell/row plumbing

/// Forwarded AppKit selection state, so hosted SwiftUI cell content can
/// switch to the white-on-accent style (AppKit cannot signal it directly).
@MainActor
private protocol SelectionStateReceiving: AnyObject {
    func selectionDidChange(isSelected: Bool, isEmphasized: Bool)
}

/// One recycled table cell hosting a SwiftUI view; the coordinator swaps
/// the root view on reuse and the per-cell selection state flows in
/// through OutlineRowSelectionState.
private final class BottomCellView<Content: View>: NSView, SelectionStateReceiving {
    let selectionState = OutlineRowSelectionState()
    let host: NSHostingView<Content?>

    init() {
        host = NSHostingView(rootView: nil)
        super.init(frame: .zero)
        host.sizingOptions = []
        addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func selectionDidChange(isSelected: Bool, isEmphasized: Bool) {
        guard selectionState.isSelected != isSelected
            || selectionState.isEmphasized != isEmphasized else { return }
        selectionState.isSelected = isSelected
        selectionState.isEmphasized = isEmphasized
    }
}

/// Standard row highlight; only exists to forward selection/focus state to
/// the hosted cells.
private final class BottomRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { forwardSelectionState() }
    }

    override var isEmphasized: Bool {
        didSet { forwardSelectionState() }
    }

    private func forwardSelectionState() {
        for case let cell as SelectionStateReceiving in subviews {
            cell.selectionDidChange(isSelected: isSelected, isEmphasized: isEmphasized)
        }
        needsDisplay = true
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SelectionStateReceiving)?
            .selectionDidChange(isSelected: isSelected, isEmphasized: isEmphasized)
    }
}
