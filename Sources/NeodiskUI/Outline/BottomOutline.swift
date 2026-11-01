// The multi-column file list docked below the treemap. Same rows, expansion and selection as the left column,
// so auto-reveal, search and file actions behave identically.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

/// The bottom table's columns. Name stays first; the rest reorder by dragging their headers and hide from the
/// header's menu.
enum OutlineColumn: String, CaseIterable, Sendable {
    case name, percent, size, files, modified

    /// The title in the header's menu and View > File List Columns; the header itself reads "%".
    var menuTitle: String {
        switch self {
        case .name: NSLocalizedString("Name", comment: "Bottom outline column header")
        case .percent: NSLocalizedString("Percentage", comment: "Bottom outline column, in the header's menu")
        case .size: NSLocalizedString("Size", comment: "Bottom outline column header")
        case .files: NSLocalizedString("Files", comment: "Bottom outline column header: descendant file count")
        case .modified: NSLocalizedString("Modified", comment: "Bottom outline column header")
        }
    }
}

// MARK: - Pane

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
                    selection: model.selection,
                    sort: model.outlineSort,
                    columns: model.outlineColumns
                )
            }
        }
    }
}

// MARK: - Table

/// AppKit, not SwiftUI Table, for reliable scroll-to-row, mid-click reload protection and recycling on huge
/// trees. Header sorts reorder siblings in the model's flattening, never the store.
struct BottomOutlineTable: NSViewRepresentable {
    let model: NeodiskViewModel
    let snapshot: NeodiskViewModel.OutlineRowsSnapshot
    let selection: NodeSelection
    let sort: OutlineSort
    /// Read here so a change from the View menu reaches the table as well as one from its header.
    let columns: ItemLayout<OutlineColumn>

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OutlineNSTableView()
        tableView.copyRequested = { [model] in model.copySelection() }
        tableView.canCopy = { [model] in model.selectionSupportsFileActions }
        tableView.quickLookRequested = { [weak coordinator] in
            coordinator?.toggleQuickLook() ?? false
        }
        tableView.hierarchyNavigationRequested = { [weak coordinator] direction, recursively in
            coordinator?.navigateHierarchy(direction, recursively: recursively)
        }
        tableView.clickTrackingEnded = { [weak coordinator] in
            coordinator?.resyncSelectionAfterClick()
        }
        tableView.rowHeight = OutlineRowMetrics.rowHeight
        tableView.backgroundColor = .controlBackgroundColor
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let textScale = OutlineRowMetrics.scale
        coordinator.appliedTextScale = textScale
        let layout = model.outlineColumns
        coordinator.appliedColumns = layout
        for id in layout.order {
            guard let spec = Self.columns.first(where: { $0.identifier == id.rawValue }) else { continue }
            let column = NSTableColumn(identifier: .init(spec.identifier))
            column.isHidden = layout.isHidden(id)
            column.title = spec.title
            // Numeric columns must not clip, so they scale; Name autoresizes and middle-truncates, so scaling
            // it too would push the numbers off-screen.
            column.width = Self.scaled(spec.width, column: spec.identifier, by: textScale)
            column.minWidth = Self.scaled(spec.minWidth, column: spec.identifier, by: textScale)
            column.resizingMask = spec.identifier == "name"
                ? [.autoresizingMask, .userResizingMask]
                : .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.sortKey,
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
        tableView.allowsNodeDrags()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = coordinator
        tableView.menu = menu

        let headerMenu = NSMenu()
        headerMenu.autoenablesItems = false
        headerMenu.delegate = coordinator
        tableView.headerView?.menu = headerMenu
        coordinator.scaleHeader(of: tableView, to: textScale)
        coordinator.headerMenu = headerMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView

        // A narrower pane drops trailing columns instead of cutting one off.
        let clipView = scrollView.contentView
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.clipFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: clipView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(snapshot: snapshot)
        coordinator.applyTextScale(columnMinimums: Self.columnMinimums)
        coordinator.applyColumns(columns)
        coordinator.applySortIndicator(sort)
        coordinator.syncSelection(to: selection)
    }

    /// The percentage label's width at 100%; its bar doesn't need to grow with the text.
    static let percentLabelWidth: CGFloat = 36

    /// A column's width at a text scale: numbers grow with the text; the percentage column only by its label;
    /// Name not at all (it autoresizes into what's left).
    static func scaled(_ width: CGFloat, column: String, by scale: CGFloat) -> CGFloat {
        switch column {
        case "name": width
        case "percent": width + percentLabelWidth * (scale - 1)
        default: width * scale
        }
    }

    /// Per-column 100% minimum widths, keyed by identifier — the coordinator
    /// rescales against these when the workspace text size changes.
    private static var columnMinimums: [String: CGFloat] {
        Dictionary(uniqueKeysWithValues: columns.map { ($0.identifier, $0.minWidth) })
    }

    private struct ColumnSpec {
        let identifier: String
        let title: String
        let width: CGFloat
        let minWidth: CGFloat
        let sortField: OutlineSortField
        let alignsTrailing: Bool

        /// The table marks every column whose key is the sort's, so the percentage column, which sorts by size
        /// too, has a key of its own; picking it sorts by size and the arrow moves to Size.
        var sortKey: String { identifier == "percent" ? identifier : sortField.rawValue }
    }

    /// The percentage column sorts by size: the bar is the size relative to
    /// the parent, so a separate order would only shuffle equal information.
    private static let columns: [ColumnSpec] = [
        ColumnSpec(
            identifier: "name",
            title: NSLocalizedString("Name", comment: "Bottom outline column header"),
            width: 320, minWidth: 140, sortField: .name, alignsTrailing: false
        ),
        ColumnSpec(
            identifier: "percent",
            title: NSLocalizedString("%", comment: "Bottom outline column header: subtree percentage"),
            width: 100, minWidth: 70, sortField: .size, alignsTrailing: false
        ),
        ColumnSpec(
            identifier: "size",
            title: NSLocalizedString("Size", comment: "Bottom outline column header"),
            width: 90, minWidth: 70, sortField: .size, alignsTrailing: true
        ),
        ColumnSpec(
            identifier: "files",
            title: NSLocalizedString("Files", comment: "Bottom outline column header: descendant file count"),
            width: 80, minWidth: 60, sortField: .files, alignsTrailing: true
        ),
        ColumnSpec(
            identifier: "modified",
            title: NSLocalizedString("Modified", comment: "Bottom outline column header"),
            width: 100, minWidth: 80, sortField: .modified, alignsTrailing: true
        ),
    ]

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private let model: NeodiskViewModel
        private(set) var rows: [NeodiskViewModel.OutlineRow] = []
        private var rowIndexByID: [String: Int] = [:]
        private var appliedStructuralVersion: UInt64?
        private let selectionSync = ListSelectionSync()
        private(set) var structuralApplyCount = 0
        /// Structural rows that arrived while a click was being tracked;
        /// applied when the click finishes.
        private var pendingApply: NeodiskViewModel.OutlineRowsSnapshot?

        weak var tableView: NSTableView?
        weak var headerMenu: NSMenu?
        /// The column order and visibility the table shows; a different one from the model is applied.
        var appliedColumns = ItemLayout<OutlineColumn>(pinned: .name)
        /// The workspace text scale the row height and columns were last
        /// laid out for; a change rescales both (see applyTextScale).
        var appliedTextScale: CGFloat = 1
        weak var scrollView: NSScrollView?

        init(model: NeodiskViewModel) {
            self.model = model
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func clipFrameDidChange(_ notification: Notification) {
            fitColumns()
        }

        /// The inset style's margins either side of the columns.
        private static let insetPadding: CGFloat = 20

        /// The Name column's room at 100% text before % or the columns after it may take more of the pane.
        private static let readableNameWidth: CGFloat = 160

        /// Which columns a narrow pane keeps longest: Name, then Size, then the rest.
        private static let fitPriority: [OutlineColumn] = [.name, .size, .percent, .files, .modified]

        /// Shows the layout's columns that fit whole, by `fitPriority` (Name always stays), so a narrow pane
        /// never cuts a column mid-value. Not persisted: they come back as room does.
        func fitColumns() {
            guard let tableView else { return }
            let spacing = tableView.intercellSpacing.width
            // Before the first layout there's no width to fit: every layout column shows.
            let width = scrollView?.contentView.bounds.width ?? 0
            var room = width > 0 ? width - Self.insetPadding : .greatestFiniteMagnitude
            // Past Name and Size, Name keeps room for a readable name at the current text size before any other
            // column shows: Size still shows beside a short Name, % never squeezes Name.
            var nameReserve: CGFloat = 0
            // Once a column misses, the less important ones stay out too, even narrower ones (% never shows
            // without Size).
            var isFull = false
            for id in Self.fitPriority {
                let index = tableView.column(withIdentifier: .init(id.rawValue))
                guard index >= 0 else { continue }
                let column = tableView.tableColumns[index]
                var shows = !appliedColumns.isHidden(id)
                if shows {
                    if id == .name {
                        room -= column.minWidth + spacing
                        nameReserve = max(0, Self.readableNameWidth * appliedTextScale - column.minWidth)
                    } else {
                        let needed = column.width + spacing
                        if isFull || room < needed + (id == .size ? 0 : nameReserve) {
                            isFull = true
                            shows = false
                        } else {
                            room -= needed
                        }
                    }
                }
                if column.isHidden == shows { column.isHidden = !shows }
            }
            tableView.sizeToFit()
        }

        /// Header titles grow with the rows, the header's height with them (AppKit's header is a fixed small size).
        func scaleHeader(of tableView: NSTableView, to scale: CGFloat) {
            let font = NSFont.systemFont(ofSize: (NSFont.smallSystemFontSize * scale).rounded(), weight: .medium)
            for column in tableView.tableColumns {
                // The header draws its attributed title; a plain font change doesn't reach it.
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = column.headerCell.alignment
                paragraph.lineBreakMode = .byTruncatingTail
                column.headerCell.attributedStringValue = NSAttributedString(
                    string: column.title,
                    attributes: [.font: font, .foregroundColor: NSColor.headerTextColor, .paragraphStyle: paragraph]
                )
            }
            guard let header = tableView.headerView else { return }
            let height = max(28, (font.boundingRectForFont.height + 12).rounded())
            if header.frame.height != height {
                header.frame.size.height = height
                tableView.enclosingScrollView?.tile()
            }
        }

        /// Scales current widths rather than the spec, so a column the user widened stays proportionally wide.
        func applyTextScale(columnMinimums: [String: CGFloat]) {
            guard let tableView else { return }
            let scale = OutlineRowMetrics.scale
            if tableView.rowHeight != OutlineRowMetrics.rowHeight {
                tableView.rowHeight = OutlineRowMetrics.rowHeight
            }
            guard scale != appliedTextScale else { return }
            let ratio = scale / appliedTextScale
            let appliedScaleBefore = appliedTextScale
            appliedTextScale = scale
            scaleHeader(of: tableView, to: scale)
            for column in tableView.tableColumns {
                let id = column.identifier.rawValue
                let minimum = BottomOutlineTable.scaled(columnMinimums[id] ?? 60, column: id, by: scale)
                column.minWidth = minimum
                // Name autoresizes into the leftover width; only its floor moves. The percentage column grows by
                // its label alone. See the makeNSView note.
                let target = switch id {
                case "name": column.width
                case "percent": column.width + BottomOutlineTable.percentLabelWidth * (scale - appliedScaleBefore)
                default: column.width * ratio
                }
                column.width = max(target, minimum)
            }
            fitColumns()
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
            let sameRows = rows.count == snapshot.rows.count
                && zip(rows, snapshot.rows).allSatisfy { $0.id == $1.id }
            rows = snapshot.rows
            rowIndexByID = snapshot.rowIndexByID
            maxDepth = rows.lazy.map(\.depth).max() ?? 0
            updateIndent()
            structuralApplyCount += 1
            selectionSync.whileApplying { tableView?.reloadRows(keepingRowViews: sameRows) }
        }

        private var maxDepth = 0
        /// The indentation per level the name cells use.
        private(set) var indentPerDepth = OutlineRowMetrics.indentPerDepth

        /// A deep tree may indent across at most 40% of the Name column: past that every level indents less
        /// (down to 4pt, so the hierarchy still reads) and names keep their room. True when it changed.
        @discardableResult
        private func updateIndent() -> Bool {
            let standard = OutlineRowMetrics.indentPerDepth
            var indent = standard
            if maxDepth > 0, let tableView,
               case let index = tableView.column(withIdentifier: .init(OutlineColumn.name.rawValue)), index >= 0 {
                let budget = tableView.tableColumns[index].width * 0.4
                indent = max(4, min(standard, (budget / CGFloat(maxDepth)).rounded(.down)))
            }
            guard indent != indentPerDepth else { return false }
            indentPerDepth = indent
            return true
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView, updateIndent() else { return }
            let nameIndex = tableView.column(withIdentifier: .init(OutlineColumn.name.rawValue))
            let visible = tableView.rows(in: tableView.visibleRect)
            guard nameIndex >= 0, visible.length > 0 else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                columnIndexes: [nameIndex]
            )
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

        func syncSelection(to selection: NodeSelection) {
            guard let tableView else { return }
            let reveal = selectionSync.apply(
                selection, rowsVersion: appliedStructuralVersion ?? 0, to: tableView, row: { rowIndexByID[$0] }
            )
            if let reveal { scrollToRowVerticalOnly(reveal) }
        }

        func resyncSelectionAfterClick() {
            if let pendingApply {
                apply(snapshot: pendingApply)
            }
            syncSelection(to: model.selection)
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

        /// Typing a name selects the next row that starts with it, as in Finder's lists.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard row < rows.count, tableColumn?.identifier.rawValue == "name" else { return nil }
            return rows[row].node.name
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
                        model: model, row: outlineRow, state: state, leadingInset: 0,
                        indentPerDepth: indentPerDepth
                    )
                }
            case "percent":
                return hostedCell(tableView, reuse: "percent") { state in
                    CleanupDimming(
                        cleanup: model.cleanup, nodeID: outlineRow.node.id, state: state,
                        content: SubtreePercentCell(fraction: outlineRow.fractionOfParent, state: state)
                    )
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
                    CleanupDimming(
                        cleanup: model.cleanup, nodeID: outlineRow.node.id, state: state,
                        content: BottomDetailText(text: files, state: state)
                    )
                }
            case "modified":
                let modified = outlineRow.node.lastModified?
                    .formatted(date: .abbreviated, time: .omitted) ?? ""
                return hostedCell(tableView, reuse: "modified") { state in
                    CleanupDimming(
                        cleanup: model.cleanup, nodeID: outlineRow.node.id, state: state,
                        content: BottomDetailText(text: modified, state: state)
                    )
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
            guard let tableView, let picked = selectionSync.userSelection(in: tableView, id: { row in
                row < rows.count ? rows[row].id : nil
            }) else { return }
            selectionSync.report(picked) {
                model.select(fromList: picked) { rowIndexByID[$0] != nil }
            }
        }

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            if key == "percent" {
                // Largest first, as the bar reads; re-marks the header on Size.
                tableView.sortDescriptors = [NSSortDescriptor(key: OutlineSortField.size.rawValue, ascending: false)]
                return
            }
            guard let field = OutlineSortField(rawValue: key) else { return }
            let sort = OutlineSort(field: field, ascending: descriptor.ascending)
            if let preferences = model.preferences, preferences.outlineSort != sort {
                preferences.outlineSort = sort
            }
        }

        // MARK: Dragging

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < rows.count else { return nil }
            return NodeDragSource.pasteboardItem(forNodeID: rows[row].node.id, model: model)
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
        ) {
            NodeDragSource.tableSessionDidBegin(session, in: tableView, at: screenPoint, model: model)
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint, operation: NSDragOperation
        ) {
            NodeDragSource.sessionDidEnd(model: model)
        }

        // MARK: Row actions (parity with `fileNodeActions`)

        @objc func didDoubleClick(_ sender: Any?) {
            guard let tableView,
                  case let row = tableView.clickedRow, row >= 0, row < rows.count else { return }
            let node = rows[row].node
            model.select(node.id)
            model.activate(node)
        }

        // MARK: Columns

        /// Set while the table is rearranged to match the model: each `moveColumn` reports a half-done order.
        private var isApplyingColumns = false

        func applyColumns(_ layout: ItemLayout<OutlineColumn>) {
            guard let tableView, layout != appliedColumns else { return }
            appliedColumns = layout
            isApplyingColumns = true
            defer { isApplyingColumns = false }
            for (index, id) in layout.order.enumerated() {
                let current = tableView.column(withIdentifier: .init(id.rawValue))
                guard current >= 0 else { continue }
                if current != index { tableView.moveColumn(current, toColumn: index) }
            }
            fitColumns()
        }

        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            columnIndex != 0 && newColumnIndex != 0
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView, !isApplyingColumns else { return }
            var layout = appliedColumns
            // Columns dropped for room keep their place: only the layout's hidden ones are out of the order.
            layout.setVisibleOrder(tableView.tableColumns.compactMap {
                OutlineColumn(rawValue: $0.identifier.rawValue)
            }.filter { !layout.isHidden($0) })
            commitColumns(layout)
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let column = OutlineColumn(rawValue: id) else { return }
            var layout = appliedColumns
            layout.setHidden(column, !layout.isHidden(column))
            commitColumns(layout)
            fitColumns()
        }

        private func commitColumns(_ layout: ItemLayout<OutlineColumn>) {
            guard layout != model.outlineColumns else { return }
            appliedColumns = layout
            model.setOutlineColumns(layout)
        }

        private func fillHeaderMenu(_ menu: NSMenu) {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                guard let id = OutlineColumn(rawValue: column.identifier.rawValue), id != .name else { continue }
                let item = NSMenuItem(title: id.menuTitle, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id.rawValue
                item.state = appliedColumns.isHidden(id) ? .off : .on
                item.isEnabled = appliedColumns.isHidden(id) || appliedColumns.canHide(id)
                menu.addItem(item)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            // The header and the empty space below the rows both customize the list.
            guard menu !== headerMenu, case let row = tableView.clickedRow, row >= 0, row < rows.count else {
                fillHeaderMenu(menu)
                menu.addItem(.separator())
                menu.addFileListLayoutItems(model: model)
                return
            }
            let node = rows[row].node
            guard model.supportsFileActions(node) else { return }
            menu.addFileNodeActionItems(for: node, model: model)
        }

        func toggleQuickLook() -> Bool {
            guard !model.selection.isEmpty else { return false }
            model.quickLookSelection()
            return true
        }

        func navigateHierarchy(_ direction: OutlineHierarchyDirection, recursively: Bool = false) {
            guard let tableView else { return }
            let performed = OutlineKeyboardNavigation.perform(
                direction, recursively: recursively, in: tableView, rows: rows, model: model
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
    @Environment(\.neoTextScale) private var textScale

    let fraction: Double
    let state: OutlineRowSelectionState

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2 * textScale)
                        .fill(state.showsAccentSelection
                            ? AnyShapeStyle(.white.opacity(0.25))
                            : AnyShapeStyle(.quaternary))
                    RoundedRectangle(cornerRadius: 2 * textScale)
                        .fill(state.showsAccentSelection
                            ? AnyShapeStyle(.white.opacity(0.9))
                            : AnyShapeStyle(Color.accentColor.opacity(0.65)))
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: (5 * textScale).rounded())

            Text(percentText)
                .neoFont(12)
                .monospacedDigit()
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white.opacity(0.85))
                    : AnyShapeStyle(.secondary))
                // "100%" at the row font; grows with it so the number
                // never truncates against the bar.
                .frame(width: (BottomOutlineTable.percentLabelWidth * textScale).rounded(), alignment: .trailing)
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
            .neoFont(12)
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

/// The coordinator swaps the root view on reuse; selection state flows in through OutlineRowSelectionState.
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

/// Standard row highlight, forwarding selection/focus state to the hosted cells. A run of selected rows reads
/// as one block: the corners they share are filled square.
private final class BottomRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { forwardSelectionState() }
    }

    override var isEmphasized: Bool {
        didSet { forwardSelectionState() }
    }

    override var isPreviousRowSelected: Bool {
        didSet { if isPreviousRowSelected != oldValue { needsDisplay = true } }
    }

    override var isNextRowSelected: Bool {
        didSet { if isNextRowSelected != oldValue { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        guard isSelected, selectionHighlightStyle != .none, isPreviousRowSelected || isNextRowSelected else { return }
        let color: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        // The inset style's highlight keeps this much off each side.
        let pill = bounds.insetBy(dx: OutlineRowMetrics.selectionInset, dy: 0)
        for half in OutlineTableRowView.squaredHalves(
            of: pill, top: isPreviousRowSelected, bottom: isNextRowSelected, isFlipped: isFlipped
        ) {
            half.fill()
        }
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
