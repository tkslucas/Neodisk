// AppKit list for the long statistics lists: a SwiftUI List past ~256 rows re-measures inside the table's own
// update pass (a reentrant delegate operation AppKit plans to assert on). Fixed-height rows never measure.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

/// What clicking a row does.
enum StatsListClick {
    /// Changes routes a deleted entry to its nearest surviving ancestor; other gestures are the usual file actions.
    case selectsNode((String) -> Void)
    /// Rows are buttons into a drill-in: a click opens the row's ID and
    /// leaves no selection behind.
    case opens((String) -> Void)
}

/// A 12pt name over a 10pt detail line plus the 10pt of air the SwiftUI List gave (37pt at 100%).
enum StatsListMetrics {
    /// The rows' content inset, which the panes' headers and footers share so everything starts on one edge.
    @MainActor static var inset: CGFloat { OutlineRowMetrics.contentInset }

    static func rowHeight(scale: CGFloat) -> CGFloat {
        ceil(lineHeight(12 * scale) + 1 + lineHeight(10 * scale)) + 10
    }

    private static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return font.ascender - font.descender + font.leading
    }
}

struct StatsListTable<Row: Identifiable, RowContent: View>: NSViewRepresentable where Row.ID == String {
    @Environment(\.neoTextScale) private var textScale

    let model: NeodiskViewModel
    let rows: [Row]
    let click: StatsListClick
    /// Read by the caller so a selection change reaches the table.
    var selection = NodeSelection()
    /// A refreshed ranking keeps its rows while the new one arrives, so the list would stay anchored otherwise.
    var keepsLeaderInView = false
    /// Esc with the list focused, as the drill-ins' back button.
    var onCancel: (() -> Void)?
    /// A note after the last row ("Top 500 of 6,000 files"): it scrolls with the list, so only the end shows it.
    var footer: String?
    @ViewBuilder let content: (Row) -> RowContent

    func makeCoordinator() -> StatsListCoordinator {
        StatsListCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OutlineNSTableView()
        tableView.copyRequested = { [model] in model.copySelection() }
        tableView.canCopy = { [model] in model.selectionSupportsFileActions }
        tableView.quickLookRequested = { [weak coordinator] in
            coordinator?.toggleQuickLook() ?? false
        }
        tableView.cancelRequested = { [weak coordinator] in
            guard let onCancel = coordinator?.onCancel else { return false }
            onCancel()
            return true
        }
        tableView.clickTrackingEnded = { [weak coordinator] in
            coordinator?.clickTrackingEnded()
        }
        tableView.style = .fullWidth
        tableView.headerView = nil
        tableView.rowHeight = StatsListMetrics.rowHeight(scale: textScale)
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .controlBackgroundColor
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: .init("stats"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.action = #selector(StatsListCoordinator.didClick)
        tableView.doubleAction = #selector(StatsListCoordinator.didDoubleClick)
        tableView.allowsNodeDrags()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: OutlineRowMetrics.verticalContentInset, left: 0,
            bottom: OutlineRowMetrics.verticalContentInset, right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(
            top: -OutlineRowMetrics.verticalContentInset, left: 0,
            bottom: -OutlineRowMetrics.verticalContentInset, right: 0
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -OutlineRowMetrics.verticalContentInset))

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let rows = rows
        let content = content
        context.coordinator.onCancel = onCancel
        context.coordinator.apply(
            StatsListCoordinator.Update(
                ids: rows.map(\.id),
                cell: { AnyView(content(rows[$0])) },
                click: click,
                selection: selection,
                keepsLeaderInView: keepsLeaderInView,
                footer: footer,
                textScale: textScale
            )
        )
    }
}

@MainActor
final class StatsListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    struct Update {
        let ids: [String]
        let cell: (Int) -> AnyView
        let click: StatsListClick
        let selection: NodeSelection
        let keepsLeaderInView: Bool
        var footer: String?
        var textScale: CGFloat = 1
    }

    private let model: NeodiskViewModel
    private var current = Update(
        ids: [], cell: { _ in AnyView(EmptyView()) }, click: .opens { _ in },
        selection: NodeSelection(), keepsLeaderInView: false
    )
    private var rowByID: [String: Int] = [:]
    /// An update that arrived while a click was being tracked: reloading
    /// then would clear the row under the mouse, so it waits for mouse-up.
    private var pending: Update?
    private let selectionSync = ListSelectionSync()
    /// Bumped with every new set of rows, so the selection is mirrored onto them.
    private var rowsVersion: UInt64 = 0

    weak var tableView: OutlineNSTableView?
    weak var scrollView: NSScrollView?
    var onCancel: (() -> Void)?

    init(model: NeodiskViewModel) {
        self.model = model
    }

    private var selectsNodes: Bool {
        if case .selectsNode = current.click { return true }
        return false
    }

    func apply(_ update: Update) {
        guard let tableView else { return }
        if tableView.isTrackingClick {
            pending = update
            return
        }
        pending = nil
        let sameIDs = update.ids == current.ids
        // A footer that comes, goes or changes is a row too.
        let sameRows = sameIDs && update.footer == current.footer
        let newLeader = update.ids.first != current.ids.first
        current = update
        if !sameIDs {
            rowByID = Dictionary(update.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            rowsVersion &+= 1
        }
        let rowHeight = StatsListMetrics.rowHeight(scale: update.textScale)
        if tableView.rowHeight != rowHeight {
            tableView.rowHeight = rowHeight
        }
        tableView.menu = rowsMenu()
        tableView.allowsMultipleSelection = selectsNodes
        // Same rows: refresh the visible cells in place (sizes, palette,
        // the cloud-only toggle); new rows: reload.
        selectionSync.whileApplying { tableView.reloadRows(keepingRowViews: sameRows) }
        if update.keepsLeaderInView, newLeader, let scrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -OutlineRowMetrics.verticalContentInset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        syncSelection()
    }

    /// A file row's actions; below the rows, which statistics tabs show.
    private func rowsMenu() -> NSMenu {
        let menu = tableView?.menu ?? NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    private func syncSelection() {
        guard let tableView else { return }
        let selection = selectsNodes ? current.selection : NodeSelection()
        _ = selectionSync.apply(selection, rowsVersion: rowsVersion, to: tableView, row: { rowByID[$0] })
    }

    func clickTrackingEnded() {
        if let pending {
            apply(pending)
        } else {
            syncSelection()
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        current.ids.count + (current.footer == nil ? 0 : 1)
    }

    private func isFooter(_ row: Int) -> Bool {
        row == current.ids.count && current.footer != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isFooter(row) ? StatsListFooterView.height(scale: current.textScale) : tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isFooter(row), let footer = current.footer {
            let view = tableView.makeView(withIdentifier: StatsListFooterView.reuseIdentifier, owner: nil)
                as? StatsListFooterView ?? StatsListFooterView()
            view.configure(footer, scale: current.textScale)
            return view
        }
        guard row < current.ids.count else { return nil }
        let cell = tableView.makeView(withIdentifier: StatsListCellView.reuseIdentifier, owner: nil)
            as? StatsListCellView ?? StatsListCellView()
        cell.configure(current.cell(row), scale: current.textScale)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // The footer is text, not an item: no hover, no selection.
        if isFooter(row) { return NSTableRowView() }
        let identifier = NSUserInterfaceItemIdentifier("StatsListRow")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? OutlineTableRowView {
            return reused
        }
        let rowView = OutlineTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        selectsNodes && row < current.ids.count
    }

    /// Select All and shift-extends stop at the last item, short of the footer.
    func tableView(
        _ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet
    ) -> IndexSet {
        proposed.filteredIndexSet { $0 < current.ids.count }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView, case .selectsNode(let select) = current.click else { return }
        let ids = current.ids
        guard let picked = selectionSync.userSelection(in: tableView, id: { $0 < ids.count ? ids[$0] : nil })
        else { return }
        selectionSync.report(picked) {
            if picked.isSingle, let id = picked.ids.first {
                // One row: the list's own pick (Changes routes a deleted entry to the folder that held it).
                if id != model.selectedNodeID || model.selection.isMultiple { select(id) }
            } else if !picked.ids.isEmpty || picked.extending {
                // (An empty plain pick is a click below the rows: the selection stays, as it always has.)
                // Several rows: only items still in the tree join (a deleted change has no node).
                let store = model.store
                let live = ListSelection(
                    ids: picked.ids.filter { store?.node(id: $0) != nil },
                    primary: picked.primary,
                    extending: picked.extending
                )
                model.select(fromList: live) { rowByID[$0] != nil }
            }
        }
    }

    // MARK: Dragging

    /// Only lists of items drag; rows that open a drill-in (kinds, duplicate groups) don't.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard selectsNodes, row < current.ids.count else { return nil }
        return NodeDragSource.pasteboardItem(forNodeID: current.ids[row], model: model)
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

    // MARK: Row actions

    private var clickedID: String? {
        guard let row = tableView?.clickedRow, row >= 0, row < current.ids.count else { return nil }
        return current.ids[row]
    }

    @objc func didClick(_ sender: Any?) {
        guard case .opens(let open) = current.click, let id = clickedID else { return }
        open(id)
    }

    /// Double-click reveals in Finder, like double-clicking a treemap cell.
    @objc func didDoubleClick(_ sender: Any?) {
        guard selectsNodes, let id = clickedID,
              let node = model.store?.node(id: id), model.supportsFileActions(node) else { return }
        model.select(id)
        model.reveal(node)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = tableView?.clickedRow, row >= 0, !isFooter(row) else {
            menu.addAnalysisTabItems(model: model)
            return
        }
        guard selectsNodes, let id = clickedID,
              let node = model.store?.node(id: id), model.supportsFileActions(node) else { return }
        menu.addFileNodeActionItems(for: node, model: model, includeExpandContents: false)
    }

    func toggleQuickLook() -> Bool {
        guard selectsNodes, !model.selection.isEmpty else { return false }
        model.quickLookSelection()
        return true
    }
}

/// Hosting views sit outside the SwiftUI environment, so the text scale is passed in; storing it also
/// re-renders a reused cell when only the scale changed (issue #10).
private final class StatsListCellView: NSView, SelectionStateReceiving {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("StatsListCell")

    private let selectionState = OutlineRowSelectionState()
    private let host = NSHostingView<StatsListCellContent?>(rootView: nil)
    private var hostLeading: NSLayoutConstraint!
    private var hostTrailing: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        hostLeading = host.leadingAnchor.constraint(equalTo: leadingAnchor)
        hostTrailing = host.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            hostLeading, hostTrailing,
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ content: AnyView, scale: CGFloat) {
        host.rootView = StatsListCellContent(content: content, state: selectionState, scale: scale)
    }

    func selectionDidChange(isSelected: Bool, isEmphasized: Bool) {
        guard selectionState.isSelected != isSelected
            || selectionState.isEmphasized != isEmphasized else { return }
        selectionState.isSelected = isSelected
        selectionState.isEmphasized = isEmphasized
    }

    override func layout() {
        super.layout()
        // The .fullWidth style insets the cell a few points inside the row;
        // span the row so the content sits exactly at the List's inset.
        guard let row = superview else { return }
        let leading = -frame.minX
        let trailing = row.bounds.width - frame.maxX
        if hostLeading.constant != leading { hostLeading.constant = leading }
        if hostTrailing.constant != trailing { hostTrailing.constant = trailing }
    }
}

/// The list's closing note, on the rows' inset.
private final class StatsListFooterView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("StatsListFooter")

    static func height(scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10 * scale)
        return ceil(font.ascender - font.descender + font.leading) + 14
    }

    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ text: String, scale: CGFloat) {
        label.stringValue = text
        label.font = .systemFont(ofSize: 10 * scale)
    }

    override func layout() {
        super.layout()
        // As the rows: the content inset from the row's edge, whatever the .fullWidth style's cell inset.
        let inset = OutlineRowMetrics.contentInset - frame.minX
        if leading.constant != inset { leading.constant = inset }
    }
}

private struct StatsListCellContent: View {
    let content: AnyView
    let state: OutlineRowSelectionState
    let scale: CGFloat

    var body: some View {
        content
            .environment(\.neoTextScale, scale)
            // The List's selected-row look: hierarchical styles (primary,
            // secondary) turn white on the accent fill.
            .environment(\.backgroundProminence, state.showsAccentSelection ? .increased : .standard)
            .padding(.horizontal, OutlineRowMetrics.contentInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
