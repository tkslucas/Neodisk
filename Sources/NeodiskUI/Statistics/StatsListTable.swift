//
//  StatsListTable.swift
//  Neodisk
//
//  The AppKit list behind the statistics panel's long lists (Largest, the
//  Kind and Age drill-ins, Changes, Duplicates). A SwiftUI List measures
//  every row's height, and past about 256 rows an update re-measures them
//  inside the table's own update pass, which AppKit logs as a reentrant
//  delegate operation it plans to turn into an assert. These rows all have
//  the same height, so the table never measures one, and scrolling a few
//  thousand rows costs nothing. Rows stay SwiftUI in per-row hosting
//  views, like the outline's.
//

import AppKit
import SwiftUI
import NeodiskKit

/// What clicking a row does.
enum StatsListClick {
    /// Rows are files: the row whose ID is the model's selected node shows
    /// selected, and a click selects through `select` (Changes routes a
    /// deleted entry to its nearest surviving ancestor). Right-click,
    /// double-click and space are the file actions of the other file lists.
    case selectsNode((String) -> Void)
    /// Rows are buttons into a drill-in: a click opens the row's ID and
    /// leaves no selection behind.
    case opens((String) -> Void)
}

/// Height of a statistics list row: a 12pt name over a 10pt detail line
/// with 1pt between, plus the 10pt of air the SwiftUI List gave the same
/// rows (37pt at 100%). Every row view shown in the table has that shape.
enum StatsListMetrics {
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
    var selectedID: String?
    /// Scroll back to the top when another row takes the lead. A refreshed
    /// size ranking keeps its rows while the new one arrives, so the list
    /// would otherwise stay anchored as bigger files land above.
    var keepsLeaderInView = false
    @ViewBuilder let content: (Row) -> RowContent

    func makeCoordinator() -> StatsListCoordinator {
        StatsListCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OutlineNSTableView()
        tableView.quickLookRequested = { [weak coordinator] in
            coordinator?.toggleQuickLook() ?? false
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
        context.coordinator.apply(
            StatsListCoordinator.Update(
                ids: rows.map(\.id),
                cell: { AnyView(content(rows[$0])) },
                click: click,
                selectedID: selectedID,
                keepsLeaderInView: keepsLeaderInView,
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
        let selectedID: String?
        let keepsLeaderInView: Bool
        var textScale: CGFloat = 1
    }

    private let model: NeodiskViewModel
    private var current = Update(
        ids: [], cell: { _ in AnyView(EmptyView()) }, click: .opens { _ in },
        selectedID: nil, keepsLeaderInView: false
    )
    private var rowByID: [String: Int] = [:]
    /// An update that arrived while a click was being tracked: reloading
    /// then would clear the row under the mouse, so it waits for mouse-up.
    private var pending: Update?
    private var isProgrammaticSelection = false
    // Set while the table reports a selection: syncing back mid-event is reentrant.
    private var isReportingSelection = false

    weak var tableView: OutlineNSTableView?
    weak var scrollView: NSScrollView?

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
        let sameRows = update.ids == current.ids
        let newLeader = update.ids.first != current.ids.first
        current = update
        if !sameRows {
            rowByID = Dictionary(update.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let rowHeight = StatsListMetrics.rowHeight(scale: update.textScale)
        if tableView.rowHeight != rowHeight {
            tableView.rowHeight = rowHeight
        }
        tableView.menu = selectsNodes ? fileActionsMenu() : nil
        // Same rows: refresh the visible cells in place (sizes, palette,
        // the cloud-only toggle); new rows: reload.
        tableView.reloadRows(keepingRowViews: sameRows)
        if update.keepsLeaderInView, newLeader, let scrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -OutlineRowMetrics.verticalContentInset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        syncSelection()
    }

    private func fileActionsMenu() -> NSMenu {
        let menu = tableView?.menu ?? NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    private func syncSelection() {
        guard let tableView, !isReportingSelection else { return }
        let target = selectsNodes ? current.selectedID.flatMap { rowByID[$0] } : nil
        guard tableView.selectedRow != (target ?? -1) else { return }
        isProgrammaticSelection = true
        if let target {
            tableView.selectRowIndexes([target], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isProgrammaticSelection = false
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
        current.ids.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < current.ids.count else { return nil }
        let cell = tableView.makeView(withIdentifier: StatsListCellView.reuseIdentifier, owner: nil)
            as? StatsListCellView ?? StatsListCellView()
        cell.configure(current.cell(row), scale: current.textScale)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("StatsListRow")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? OutlineTableRowView {
            return reused
        }
        let rowView = OutlineTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        selectsNodes
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, let tableView,
              case .selectsNode(let select) = current.click else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < current.ids.count else { return }
        let id = current.ids[row]
        guard id != model.selectedNodeID else { return }
        isReportingSelection = true
        defer { isReportingSelection = false }
        select(id)
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
        guard selectsNodes, let id = clickedID,
              let node = model.store?.node(id: id), model.supportsFileActions(node) else { return }
        menu.addFileNodeActionItems(for: node, model: model, includeExpandContents: false)
    }

    func toggleQuickLook() -> Bool {
        guard selectsNodes, let node = model.selectedNode else { return false }
        QuickLookPresenter.shared.togglePreview(for: node)
        return true
    }
}

/// One recycled row cell hosting the caller's SwiftUI row at the List's
/// 16pt inset, switching to white-on-accent text while its row is the
/// focused selection. A hosting view sits outside the SwiftUI environment,
/// so the cell hands the workspace text scale back in; as a stored value it
/// also re-renders a reused cell when only the scale changed (issue #10).
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
