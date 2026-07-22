//
//  OutlineTreeTable.swift
//  Neodisk
//
//  The AppKit table stack backing the outline: one NSScrollView owning both
//  axes, a single-column view-based NSTableView that can grow wider than the
//  pane, and per-row hosting views that keep the rows themselves SwiftUI.
//  Row metrics mirror the old SwiftUI List so the everything-fits case is
//  indistinguishable from it (see OutlineRowMetrics).
//

import AppKit
import SwiftUI
import NeodiskKit

// MARK: - AppKit-backed outline table

/// Single-column view-based NSTableView whose column may be wider than the
/// pane: the one NSScrollView then scrolls both axes natively. Rows remain
/// SwiftUI via per-row hosting views; the view model stays the single
/// source of truth for rows, selection, and expansion.
struct OutlineTreeTable: NSViewRepresentable {
    let model: NeodiskViewModel
    let snapshot: NeodiskViewModel.OutlineRowsSnapshot
    let selectedID: String?

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
        // .fullWidth: the only style whose frame equals the column width
        // exactly — .inset pads the table beyond the column, which pushes
        // the horizontal scroller into engaging with nothing to scroll.
        // Row look (insets, rounded selection) is drawn by our row views.
        tableView.style = .fullWidth
        tableView.headerView = nil
        tableView.rowHeight = OutlineRowMetrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .controlBackgroundColor
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let column = NSTableColumn(identifier: .init("outline"))
        column.resizingMask = []
        tableView.addTableColumn(column)

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
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: OutlineRowMetrics.verticalContentInset,
            left: 0,
            bottom: OutlineRowMetrics.verticalContentInset,
            right: 0
        )
        // Scrollers position themselves inside the content insets, which
        // would float the horizontal bar 10pt above the pane's bottom edge.
        // Cancel the insets for scrollers only, so they hug the pane edges
        // exactly like the SwiftUI List's did.
        scrollView.scrollerInsets = NSEdgeInsets(
            top: -OutlineRowMetrics.verticalContentInset,
            left: 0,
            bottom: -OutlineRowMetrics.verticalContentInset,
            right: 0
        )
        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: -OutlineRowMetrics.verticalContentInset)
        )

        coordinator.tableView = tableView
        coordinator.column = column
        coordinator.scrollView = scrollView

        // Track the clip view: re-fit the column when the pane resizes
        // (the column must never fall below the visible width, or the
        // trailing sizes detach from the pane's right edge) and re-pin the
        // trailing clusters when it scrolls horizontally.
        let clipView = scrollView.contentView
        clipView.postsFrameChangedNotifications = true
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.clipFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: clipView
        )
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.clipBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(snapshot: snapshot)
        coordinator.applyColumnWidth()
        coordinator.syncSelection(to: selectedID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private let model: NeodiskViewModel
        private(set) var rows: [NeodiskViewModel.OutlineRow] = []
        private var rowIndexByID: [String: Int] = [:]
        private var appliedStructuralVersion: UInt64?
        private var contentWidth: CGFloat = 0
        private(set) var structuralApplyCount = 0
        /// Last measured gap between the table's frame and its single
        /// column (the style's horizontal padding).
        private var columnOverhead: CGFloat = 12
        private var isProgrammaticSelection = false
        /// The selection the outline last scrolled to: reveal again only
        /// when the model's selection actually changes, not on reloads.
        private var lastRevealedID: String?

        weak var tableView: NSTableView?
        weak var column: NSTableColumn?
        weak var scrollView: NSScrollView?

        init(model: NeodiskViewModel) {
            self.model = model
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Structural rows that arrived while a click was being tracked;
        /// applied when the click finishes.
        private var pendingApply: NeodiskViewModel.OutlineRowsSnapshot?

        func apply(snapshot: NeodiskViewModel.OutlineRowsSnapshot) {
            guard snapshot.structuralVersion != appliedStructuralVersion else { return }
            // Mid-click, reloading would clear the row the user is holding
            // the mouse on (and the deferred delegate would then report an
            // empty selection). Keep the table frozen until tracking ends;
            // `rows` also stays consistent with what the click landed on.
            if let outlineTable = tableView as? OutlineNSTableView,
               outlineTable.isTrackingClick {
                pendingApply = snapshot
                return
            }
            pendingApply = nil
            appliedStructuralVersion = snapshot.structuralVersion
            rows = snapshot.rows
            rowIndexByID = snapshot.rowIndexByID
            contentWidth = snapshot.contentWidth
            structuralApplyCount += 1
            tableView?.reloadData()
        }

        /// The column always spans at least the visible width and grows to
        /// the widest row, at which point the horizontal scroller engages.
        func applyColumnWidth() {
            guard let column, let scrollView, let tableView else { return }
            let clipWidth = scrollView.contentView.bounds.width
            // The table lays itself out slightly wider than its single
            // column (style padding — 12pt observed even for .fullWidth),
            // and that excess would engage the scroller with nothing to
            // scroll. Measure it from the frames rather than hard-coding —
            // but only while the table hugs its column: with the column
            // narrower than the clip, the table stretches to fill the clip
            // and the difference is meaningless. Iterate since setting the
            // width re-tiles the table.
            for _ in 0..<2 {
                if tableView.frame.width > clipWidth + 0.5 {
                    columnOverhead = max(0, tableView.frame.width - column.width)
                }
                let width = max(clipWidth, contentWidth) - columnOverhead
                guard abs(column.width - width) > 0.5 else { break }
                column.width = width
            }
        }

        @objc func clipFrameDidChange(_ notification: Notification) {
            applyColumnWidth()
            updateViewportPinning()
        }

        @objc func clipBoundsDidChange(_ notification: Notification) {
            updateViewportPinning()
        }

        /// Keeps every visible row's trailing cluster at the pane's right
        /// edge while the content scrolls, and the selection highlight
        /// spanning the visible width.
        private func updateViewportPinning() {
            tableView?.enumerateAvailableRowViews { rowView, _ in
                if let cell = rowView.subviews.first(where: { $0 is OutlineCellView }) {
                    (cell as? OutlineCellView)?.updateViewportPinning()
                }
                if rowView.isSelected {
                    rowView.needsDisplay = true
                }
            }
        }

        func syncSelection(to selectedID: String?) {
            guard let tableView else { return }
            // A click in flight: the table already shows the clicked row but
            // hasn't told us yet (the delegate fires when tracking ends).
            // Syncing now would revert the user's click to the stale model
            // value; clickTrackingEnded re-syncs once the delegate has run.
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

        /// Click tracking finished and the delegate has run: apply any rows
        /// and model selection changes that arrived (and were held) mid-click.
        func resyncSelectionAfterClick() {
            if let pendingApply {
                apply(snapshot: pendingApply)
                applyColumnWidth()
            }
            syncSelection(to: model.selectedNodeID)
        }

        /// Vertical-only reveal: never disturbs an intentional horizontal
        /// position (scrollRowToVisible could tug it since row rects span
        /// the full content width).
        private func scrollToRowVerticalOnly(_ row: Int) {
            guard let tableView, let scrollView else { return }
            scrollOutlineRowVertically(tableView.rect(ofRow: row), in: scrollView)
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard row < rows.count else { return nil }
            let cell = tableView.makeView(withIdentifier: OutlineCellView.reuseIdentifier, owner: nil)
                as? OutlineCellView ?? OutlineCellView()
            cell.configure(model: model, row: rows[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("OutlineRowBackground")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? OutlineTableRowView {
                return reused
            }
            let rowView = OutlineTableRowView()
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

// MARK: - Row view (selection highlight)

/// Draws the List-style rounded selection pinned to the visible width, so
/// it neither stretches across the whole (possibly much wider) content nor
/// slides away when the tree pans. Selection and focus state are forwarded
/// to the hosted SwiftUI row, which AppKit cannot signal directly.
private final class OutlineTableRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { forwardSelectionState() }
    }

    override var isEmphasized: Bool {
        didSet { forwardSelectionState() }
    }

    private func forwardSelectionState() {
        for case let cell as OutlineCellView in subviews {
            cell.selectionDidChange(isSelected: isSelected, isEmphasized: isEmphasized)
        }
        needsDisplay = true
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? OutlineCellView)?
            .selectionDidChange(isSelected: isSelected, isEmphasized: isEmphasized)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, selectionHighlightStyle != .none else { return }
        let visible = visibleRect
        let rect = NSRect(
            x: visible.minX + OutlineRowMetrics.selectionInset,
            y: 0,
            width: visible.width - OutlineRowMetrics.selectionInset * 2,
            height: bounds.height
        )
        let color: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: OutlineRowMetrics.selectionRadius,
            yRadius: OutlineRowMetrics.selectionRadius
        ).fill()
    }
}

// MARK: - Cell view (scrolling name + pinned trailing cluster)

/// A row: the name section fills the full content width and scrolls; the
/// trailing cluster (spinner, diff delta, size) is re-pinned to the clip
/// view's right edge as the tree pans. Long names are clipped just before
/// the cluster (`nameClipView`) rather than covered by an opaque backdrop:
/// the region between name and size then shows the row's own background,
/// which stays pixel-identical to the pane under desktop tinting — a
/// hand-painted backdrop resolves the same system color darker. Cluster
/// position uses Auto Layout so the pin only moves a constraint constant
/// per scroll frame, and intrinsic-size changes (the spinner appearing,
/// sizes updating mid-scan) reflow on their own.
private final class OutlineCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("OutlineCell")

    private let selectionState = OutlineRowSelectionState()
    private let nameClipView = NSView()
    private let nameHost: NSHostingView<OutlineNameSection?>
    private let clusterHost: NSHostingView<OutlineTrailingSection?>
    private var nameLeading: NSLayoutConstraint!
    private var clusterTrailing: NSLayoutConstraint!

    init() {
        nameHost = NSHostingView(rootView: nil)
        clusterHost = NSHostingView(rootView: nil)
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        wantsLayer = true

        nameHost.sizingOptions = []
        clusterHost.sizingOptions = .intrinsicContentSize

        // The name host keeps its full-content-width frame (so SwiftUI
        // never sees a narrow proposal and center-shifts an overflowing
        // name); the clip container cuts it off just before the cluster.
        nameClipView.clipsToBounds = true
        addSubview(nameClipView)
        nameClipView.addSubview(nameHost)
        addSubview(clusterHost)

        nameClipView.translatesAutoresizingMaskIntoConstraints = false
        nameHost.translatesAutoresizingMaskIntoConstraints = false
        clusterHost.translatesAutoresizingMaskIntoConstraints = false
        nameLeading = nameHost.leadingAnchor.constraint(equalTo: leadingAnchor)
        clusterTrailing = clusterHost.trailingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            nameClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameClipView.trailingAnchor.constraint(
                equalTo: clusterHost.leadingAnchor,
                constant: -OutlineRowMetrics.clusterLeadingMargin
            ),
            nameClipView.topAnchor.constraint(equalTo: topAnchor),
            nameClipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameLeading,
            nameHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameHost.topAnchor.constraint(equalTo: topAnchor),
            nameHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            clusterTrailing,
            clusterHost.topAnchor.constraint(equalTo: topAnchor),
            clusterHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(model: NeodiskViewModel, row: NeodiskViewModel.OutlineRow) {
        nameHost.rootView = OutlineNameSection(model: model, row: row, state: selectionState)
        clusterHost.rootView = OutlineTrailingSection(model: model, row: row, state: selectionState)
    }

    func selectionDidChange(isSelected: Bool, isEmphasized: Bool) {
        guard selectionState.isSelected != isSelected
            || selectionState.isEmphasized != isEmphasized else { return }
        selectionState.isSelected = isSelected
        selectionState.isEmphasized = isEmphasized
    }

    override func layout() {
        super.layout()
        // The .fullWidth table style still insets the cell a few points
        // inside the row; cancel it so the row content starts exactly at
        // the List's 16pt inset from the pane edge.
        if nameLeading.constant != -frame.origin.x {
            nameLeading.constant = -frame.origin.x
        }
        updateViewportPinning()
    }

    /// Pins the trailing cluster to the clip view's right edge. Called
    /// from layout and whenever the clip view scrolls.
    func updateViewportPinning() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        let visible = convert(clipView.bounds, from: clipView)
        guard abs(clusterTrailing.constant - visible.maxX) > 0.01 else { return }
        clusterTrailing.constant = visible.maxX
    }
}

/// Per-row selection/focus state bridged from AppKit into the hosted
/// SwiftUI row content, which can't receive NSTableRowView's emphasized
/// signal any other way.
@Observable
@MainActor
final class OutlineRowSelectionState {
    var isSelected = false
    var isEmphasized = false

    var showsAccentSelection: Bool { isSelected && isEmphasized }
}

/// NSTableView that toggles Quick Look on space, like the SwiftUI lists'
/// `quickLookOnSpace`. Key events only reach the table while it is first
/// responder, so typing spaces into the search field is unaffected. Shared
/// by both outline layouts (left column and bottom table).
final class OutlineNSTableView: NSTableView {
    var quickLookRequested: () -> Bool = { false }
    var hierarchyNavigationRequested: (OutlineHierarchyDirection) -> Void = { _ in }
    /// True while a click's mouse-tracking session is running. The table
    /// applies a click's selection at mouseDown but fires the delegate only
    /// when tracking ends, so mid-click the selection legitimately disagrees
    /// with the model — programmatic sync must not "correct" it back.
    private(set) var isTrackingClick = false
    var clickTrackingEnded: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", quickLookRequested() {
            return
        }
        let hierarchyModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        if hierarchyModifiers.isEmpty {
            switch event.specialKey {
            case .leftArrow:
                hierarchyNavigationRequested(.left)
                return
            case .rightArrow:
                hierarchyNavigationRequested(.right)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingClick = true
        super.mouseDown(with: event)
        isTrackingClick = false
        clickTrackingEnded()
    }
}
