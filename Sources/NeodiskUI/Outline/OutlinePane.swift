//
//  OutlinePane.swift
//  Neodisk
//
//  The left-hand outline: an expandable name/size tree over the scan,
//  flattened to visible rows so expansion can be driven programmatically
//  (treemap clicks auto-reveal their row).
//
//  Deep nesting can outgrow the pane, so the tree scrolls horizontally.
//  Design: names lay out at full natural width (never truncated) and pan
//  under a viewport-pinned trailing cluster — each row's size (and diff
//  delta) stays right-aligned at the pane edge at every scroll offset,
//  behind a short fade so long names slide beneath it. One AppKit
//  NSScrollView owns both axes (nested SwiftUI scroll views cannot pan
//  diagonally and bounce on row clicks), a single-column NSTableView
//  recycles rows, and the rows themselves stay SwiftUI. When everything
//  fits, offset is zero and the pane renders exactly like the previous
//  SwiftUI List, whose metrics are mirrored in OutlineRowMetrics.
//

import AppKit
import SwiftUI
import NeodiskKit

struct OutlinePane: View {
    let model: NeodiskViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if let results = model.search.results {
                OutlineSearchResultsList(model: model, results: results)
            } else {
                outlineTree
            }
        }
    }

    /// Entire-scan fuzzy search. Filtering never navigates or zooms — the
    /// treemap stays exactly where it is; only this pane's list changes.
    private var searchField: some View {
        @Bindable var search = model.search
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search entire scan", text: $search.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isSearchFocused)
                .onExitCommand {
                    model.search.clear()
                    isSearchFocused = false
                }
            if !model.search.text.isEmpty {
                Button {
                    model.search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.search.focusToken) { _, _ in
            isSearchFocused = true
        }
    }

    /// The AppKit-backed tree. The search field and search results live
    /// outside it and never pan horizontally.
    private var outlineTree: some View {
        OutlineTreeTable(
            model: model,
            rows: model.visibleOutlineRows(),
            selectedID: model.selectedNodeID,
            baseline: model.diff.baseline
        )
    }
}

// MARK: - Shared row metrics

/// Layout constants of the old SwiftUI List rows, measured pixel-for-pixel
/// from it: both the SwiftUI row content and the AppKit table below mirror
/// them so the everything-fits case is indistinguishable from the List.
@MainActor
private enum OutlineRowMetrics {
    /// Vertical pitch of a List row at defaultMinListRowHeight 20.
    static let rowHeight: CGFloat = 23
    /// List's leading/trailing content inset inside the pane.
    static let contentInset: CGFloat = 16
    /// List's selection is a rounded rect inset from the pane edges.
    static let selectionInset: CGFloat = 10
    static let selectionRadius: CGFloat = 5
    /// List's breathing room above the first and below the last row.
    static let verticalContentInset: CGFloat = 10
    /// Opaque margin ahead of the pinned trailing cluster: long names clip
    /// hard against it, mirroring the List's 8pt minimum name↔size gap.
    static let clusterLeadingMargin: CGFloat = 8
    /// Indentation per outline depth level.
    static let indentPerDepth: CGFloat = 14

    private static let nameFont = NSFont.systemFont(ofSize: 12)
    private static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let widthCache = NSCache<NSString, NSNumber>()

    /// Natural (untruncated) width of the widest row: the column grows to
    /// this, at which point the horizontal scroller engages. Mirrors the
    /// HStack in OutlineNameSection: inset 16 + indent + chevron 14, icon
    /// 16, three 4pt gaps, then the name, an 8pt minimum gap, and the
    /// trailing cluster at its own inset.
    static func contentWidth(
        for rows: [NeodiskViewModel.OutlineRow], baseline: ScanSizeBaseline?
    ) -> CGFloat {
        var maxWidth: CGFloat = 0
        for row in rows {
            var width = contentInset + CGFloat(row.depth) * indentPerDepth + 46
            width += cachedWidth(of: row.node.name, font: nameFont, cachePrefix: "n:")
            width += 8 + clusterWidth(for: row, baseline: baseline) + contentInset
            maxWidth = max(maxWidth, width)
        }
        return maxWidth.rounded(.up)
    }

    static func clusterWidth(
        for row: NeodiskViewModel.OutlineRow, baseline: ScanSizeBaseline?
    ) -> CGFloat {
        var width = cachedWidth(
            of: NeodiskFormatters.size(row.node.allocatedSize),
            font: sizeFont,
            cachePrefix: "s:"
        )
        if let baseline {
            width += cachedWidth(
                of: deltaText(baseline.sizeDelta(for: row.node)),
                font: sizeFont,
                cachePrefix: "s:"
            ) + 4
        }
        return width
    }

    static func deltaText(_ delta: Int64) -> String {
        if delta == 0 { return "·" }
        if delta > 0 { return "+\(NeodiskFormatters.size(delta))" }
        return "−\(NeodiskFormatters.size(-delta))"
    }

    private static func cachedWidth(of text: String, font: NSFont, cachePrefix: String) -> CGFloat {
        let key = (cachePrefix + text) as NSString
        if let cached = widthCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        widthCache.setObject(NSNumber(value: width), forKey: key)
        return width
    }
}

// MARK: - AppKit-backed outline table

/// Single-column view-based NSTableView whose column may be wider than the
/// pane: the one NSScrollView then scrolls both axes natively. Rows remain
/// SwiftUI via per-row hosting views; the view model stays the single
/// source of truth for rows, selection, and expansion.
private struct OutlineTreeTable: NSViewRepresentable {
    let model: NeodiskViewModel
    let rows: [NeodiskViewModel.OutlineRow]
    let selectedID: String?
    let baseline: ScanSizeBaseline?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = OutlineNSTableView()
        tableView.quickLookRequested = { [weak coordinator] in
            coordinator?.toggleQuickLook() ?? false
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
        coordinator.apply(rows: rows, baseline: baseline)
        coordinator.applyColumnWidth()
        coordinator.syncSelection(to: selectedID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private let model: NeodiskViewModel
        private(set) var rows: [NeodiskViewModel.OutlineRow] = []
        private var rowIndexByID: [String: Int] = [:]
        private var fingerprints: [RowFingerprint] = []
        private var contentWidth: CGFloat = 0
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

        /// Render-relevant identity of a row: reload only when the visible
        /// row list actually changes. Purely observable details (chevron
        /// rotation, the expansion spinner) update in place through the
        /// hosted SwiftUI rows without a reload.
        struct RowFingerprint: Equatable {
            let id: String
            let depth: Int
            let isExpandable: Bool
            let name: String
            let size: Int64
            let delta: Int64?
        }

        /// Row list + baseline that arrived while a click was being tracked;
        /// applied when the click finishes.
        private var pendingApply: ([NeodiskViewModel.OutlineRow], ScanSizeBaseline?)?

        func apply(rows newRows: [NeodiskViewModel.OutlineRow], baseline: ScanSizeBaseline?) {
            // Mid-click, reloading would clear the row the user is holding
            // the mouse on (and the deferred delegate would then report an
            // empty selection). Keep the table frozen until tracking ends;
            // `rows` also stays consistent with what the click landed on.
            if let outlineTable = tableView as? OutlineNSTableView,
               outlineTable.isTrackingClick {
                pendingApply = (newRows, baseline)
                return
            }
            pendingApply = nil
            let newFingerprints = newRows.map {
                RowFingerprint(
                    id: $0.id,
                    depth: $0.depth,
                    isExpandable: $0.isExpandable,
                    name: $0.node.name,
                    size: $0.node.allocatedSize,
                    delta: baseline?.sizeDelta(for: $0.node)
                )
            }
            guard newFingerprints != fingerprints else {
                rows = newRows
                return
            }
            rows = newRows
            fingerprints = newFingerprints
            rowIndexByID = Dictionary(
                uniqueKeysWithValues: newRows.enumerated().map { ($0.element.id, $0.offset) }
            )
            contentWidth = OutlineRowMetrics.contentWidth(for: newRows, baseline: baseline)
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
            if let (newRows, baseline) = pendingApply {
                apply(rows: newRows, baseline: baseline)
                applyColumnWidth()
            }
            syncSelection(to: model.selectedNodeID)
        }

        /// Vertical-only reveal: never disturbs an intentional horizontal
        /// position (scrollRowToVisible could tug it since row rects span
        /// the full content width).
        private func scrollToRowVerticalOnly(_ row: Int) {
            guard let tableView, let scrollView else { return }
            let clip = scrollView.contentView
            let rowRect = tableView.rect(ofRow: row)
            var origin = clip.bounds.origin
            if rowRect.minY < clip.bounds.minY {
                origin.y = rowRect.minY
            } else if rowRect.maxY > clip.bounds.maxY {
                origin.y = rowRect.maxY - clip.bounds.height
            } else {
                return
            }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
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
            guard node.supportsFileActions else { return }
            model.select(node.id)
            model.reveal(node)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView,
                  case let row = tableView.clickedRow, row >= 0, row < rows.count else { return }
            let node = rows[row].node
            guard node.supportsFileActions else { return }
            let model = self.model
            menu.addItem(ActionMenuItem(titleKey: "Reveal in Finder") { model.reveal(node) })
            menu.addItem(ActionMenuItem(titleKey: "Open") { model.open(node) })
            menu.addItem(ActionMenuItem(titleKey: "Copy Path") { model.copyPath(node) })
            if let expansion = model.contentsExpansion(for: node) {
                menu.addItem(.separator())
                let expand = ActionMenuItem(titleKey: expansion.menuTitleKey) {
                    model.expandNodeContents(node)
                }
                expand.isEnabled = model.canRefreshSubtree
                menu.addItem(expand)
            }
        }

        func toggleQuickLook() -> Bool {
            guard let node = model.selectedNode else { return false }
            QuickLookPresenter.shared.togglePreview(for: node)
            return true
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
private final class OutlineRowSelectionState {
    var isSelected = false
    var isEmphasized = false

    var showsAccentSelection: Bool { isSelected && isEmphasized }
}


/// NSTableView that toggles Quick Look on space, like the SwiftUI lists'
/// `quickLookOnSpace`. Key events only reach the table while it is first
/// responder, so typing spaces into the search field is unaffected.
private final class OutlineNSTableView: NSTableView {
    var quickLookRequested: () -> Bool = { false }
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
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingClick = true
        super.mouseDown(with: event)
        isTrackingClick = false
        clickTrackingEnded()
    }
}

/// NSMenuItem carrying its action as a closure, so menu items can capture
/// the clicked node directly (same shape as the SwiftUI context menu).
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(titleKey: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(
            title: NSLocalizedString(titleKey, comment: "Outline row context menu item"),
            action: #selector(invoke),
            keyEquivalent: ""
        )
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func invoke() {
        handler()
    }
}

// MARK: - Hosted row content

/// Indent, chevron, icon, and the full name — the part of a row that pans.
/// The name never truncates; when it outgrows the pane it slides under the
/// pinned trailing cluster and the tree becomes horizontally scrollable.
private struct OutlineNameSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState

    var body: some View {
        HStack(spacing: 4) {
            Color.clear
                .frame(width: CGFloat(row.depth) * OutlineRowMetrics.indentPerDepth, height: 1)

            Group {
                if row.isExpandable {
                    Button {
                        model.toggleExpansion(row.node.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(
                                .degrees(model.expandedNodeIDs.contains(row.node.id) ? 90 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chevronStyle)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)

            Image(systemName: row.node.systemImageName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 16)

            Text(row.node.name)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(.primary))

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, OutlineRowMetrics.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var chevronStyle: AnyShapeStyle {
        state.showsAccentSelection
            ? AnyShapeStyle(.white.opacity(0.85))
            : AnyShapeStyle(.secondary)
    }

    private var iconColor: Color {
        if row.node.isDirectory {
            return .secondary
        }
        return model.kinds.catalog.color(for: row.node)
    }
}

/// Spinner, diff delta, and size — the trailing cluster pinned to the
/// pane's right edge at every horizontal scroll position.
private struct OutlineTrailingSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState

    var body: some View {
        HStack(spacing: 4) {
            if model.coordinator.expandingNodeID == row.node.id {
                // A subtree rescan/expansion is scanning this folder.
                ProgressView()
                    .controlSize(.mini)
            }

            if let baseline = model.diff.baseline {
                DeltaLabel(delta: baseline.sizeDelta(for: row.node))
            }

            Text(NeodiskFormatters.size(row.node.allocatedSize))
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white.opacity(0.85))
                    : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12))
        .padding(.trailing, OutlineRowMetrics.contentInset)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Search results

/// Flat, score-ranked results of the entire-scan search. Selecting a row is
/// a normal outline selection: treemap highlight via the existing sync, and
/// ancestors expand so clearing the search shows the node in context.
private struct OutlineSearchResultsList: View {
    let model: NeodiskViewModel
    let results: SearchModel.Results

    var body: some View {
        let selection = Binding<String?>(
            get: { model.selectedNodeID },
            set: { if let id = $0 { model.select(id) } }
        )

        if results.ids.isEmpty {
            Spacer()
            Text("No matches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List(results.ids, id: \.self, selection: selection) { nodeID in
                if let node = model.store?.node(id: nodeID) {
                    FileResultRow(node: node, palette: model.vizPalette)
                        .listRowSeparator(.hidden)
                }
            }
            .fileNodeActions(model: model)
            .environment(\.defaultMinListRowHeight, 20)
            .quickLookOnSpace(model: model)

            if results.ids.count < results.totalMatches {
                Divider()
                Text("Top \(results.ids.count.formatted()) of \(results.totalMatches.formatted()) matches — refine to narrow")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// Growth since the baseline scan: "+1.2 GB" in red, "−340 MB" in green,
/// a quiet dot for unchanged nodes.
private struct DeltaLabel: View {
    let delta: Int64

    var body: some View {
        Group {
            if delta == 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
            } else if delta > 0 {
                Text("+\(NeodiskFormatters.size(delta))")
                    .foregroundStyle(.red)
            } else {
                Text("−\(NeodiskFormatters.size(-delta))")
                    .foregroundStyle(.green)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
