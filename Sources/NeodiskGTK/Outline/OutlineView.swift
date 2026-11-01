// Child rows are created only on expand, so a million-node scan never materializes a million items.
// Selection syncs both ways with the treemap.

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class OutlineView {
    let widget: GPtr
    private let model: AppModel
    private let columnView: GPtr
    private var treeModel: GObjectRef?
    private var selection: GObjectRef?
    private var builtFor: (generation: Int, rootID: String)?
    private var lastRebuild = ContinuousClock.now - .seconds(10)
    private var rebuildTask: Task<Void, Never>?
    private var isSyncingSelection = false
    /// The input that changed the rows held Ctrl or Shift: the items the outline doesn't show stay selected.
    private var isExtending = false
    private var contextMenu: GPtr?
    private var columns: [OutlineColumn: GPtr] = [:]
    /// The header menu's check items, one per column that can hide.
    private var columnActions: [OutlineColumn: GPtr] = [:]
    private var layout = ItemLayout<OutlineColumn>(pinned: .name)
    /// A narrow window: secondary columns give way to names, whatever the layout says.
    private var isCompact = false
    private var isApplyingLayout = false
    private var tokens: [ObservationToken] = []

    private static let cellKey = "neodisk-outline-cell"

    init(model: AppModel) {
        self.model = model
        columnView = raw(gtk_column_view_new(nil))!
        Widgets.addClasses(columnView, ["data-table"])
        // Dragging a header reorders; Name stays first (`columnsDidMove`).
        gtk_column_view_set_reorderable(ptr(columnView), gbool(true))

        let scrolled = Widgets.scrolled(columnView, horizontalPolicy: GTK_POLICY_AUTOMATIC)
        gtk_widget_set_size_request(ptr(scrolled), -1, 140)
        widget = scrolled
        attach(self, to: widget, key: "neodisk-outline")

        addColumn(.name, expand: true, setup: Self.setupName, bind: { [unowned self] cell, node, row in
            self.bindName(cell, node: node, row: row)
        })
        addColumn(.size, fixedWidth: 96, setup: Self.setupRightAligned, bind: { cell, node, _ in
            gtk_label_set_text(ptr(cell.label), NeodiskFormatters.size(node.allocatedSize))
        })
        addColumn(.share, fixedWidth: 120, setup: Self.setupShare, bind: { [unowned self] cell, node, _ in
            self.bindShare(cell, node: node)
        })
        addColumn(.files, fixedWidth: 84, setup: Self.setupRightAligned, bind: { cell, node, _ in
            gtk_label_set_text(ptr(cell.label), node.isDirectory ? node.descendantFileCount.formatted() : "")
        })
        addColumn(.modified, fixedWidth: 130, setup: Self.setupRightAligned, bind: { cell, node, _ in
            // An mtime of 0 (the epoch) means the filesystem doesn't track it.
            let text = node.lastModified.flatMap { $0.timeIntervalSince1970 > 0 ? $0.formatted(date: .abbreviated, time: .omitted) : nil } ?? ""
            gtk_label_set_text(ptr(cell.label), text)
        })
        installColumnMenu()
        applyLayout(ItemLayout(stored: model.preferences.outlineColumns, pinned: .name))
        connectItemsChanged(raw(gtk_column_view_get_columns(ptr(columnView)))) { [unowned self] in
            self.columnsDidMove()
        }

        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, state in
            MainWindow.handleTrashKey(keyval, state: state, from: self.columnView)
        }
        gtk_widget_add_controller(ptr(columnView), ptr(keys))

        // Seen before the view acts on them, so a selection change knows whether it extends the selection.
        let extendKeys = raw(gtk_event_controller_key_new())!
        gtk_event_controller_set_propagation_phase(ptr(extendKeys), GTK_PHASE_CAPTURE)
        connectKey(extendKeys) { [unowned self] keyval, state in
            // Ctrl+A picks exactly the outline's rows, so Delete after it never takes another view's pick.
            self.isExtending = Self.extends(state) && !TreemapView.isSelectAll(keyval, state: state)
            return false
        }
        gtk_widget_add_controller(ptr(columnView), ptr(extendKeys))
        let press = raw(gtk_gesture_click_new())!
        gtk_event_controller_set_propagation_phase(ptr(press), GTK_PHASE_CAPTURE)
        connectPress(press, "pressed") { [unowned self] _, _, _ in
            self.isExtending = Self.extends(gtk_event_controller_get_current_event_state(ptr(press)).rawValue)
        }
        gtk_widget_add_controller(ptr(columnView), ptr(press))

        connectPosition(columnView, "activate") { [unowned self] position in
            guard let node = self.node(atPosition: position), node.isDirectory else { return }
            self.model.drillIn(to: node.id)
        }

        tokens.append(track { [unowned self] in
            _ = self.model.store.map { _ in self.model.storeGeneration }
            _ = self.model.focusedRootID
            _ = self.model.phase
            self.scheduleRebuild()
        })
        tokens.append(track { [unowned self] in
            _ = self.model.selection
            self.syncSelection()
        })
    }

    // MARK: - Columns

    /// Widgets of one cell, attached to the cell's root widget in setup and
    /// filled in bind.
    private final class Cell {
        let root: GPtr
        var label: GPtr?
        var icon: GPtr?
        var expander: GPtr?
        var bar: GPtr?
        var nodeID: String?
        init(root: GPtr) { self.root = root }
    }

    private typealias Setup = @MainActor () -> Cell
    private typealias Bind = @MainActor (Cell, FileNodeRecord, GPtr) -> Void

    private func addColumn(_ id: OutlineColumn, expand: Bool = false, fixedWidth: Int? = nil, setup: @escaping Setup, bind: @escaping Bind) {
        let factory = raw(gtk_signal_list_item_factory_new())!
        connectPointer(factory, "setup") { [unowned self] listItem in
            let cell = setup()
            attach(cell, to: cell.root, key: Self.cellKey)
            self.addContextGesture(to: cell)
            gtk_list_item_set_child(ptr(listItem), ptr(cell.root))
        }
        connectPointer(factory, "bind") { [unowned self] listItem in
            guard let child = raw(gtk_list_item_get_child(ptr(listItem))),
                  let cell = attached(Cell.self, to: child, key: Self.cellKey),
                  let row = gtk_list_item_get_item(ptr(listItem)),
                  let item = gtk_tree_list_row_get_item(ptr(row)) else { return }
            defer { g_object_unref(item) }
            guard let id = string(from: gtk_string_object_get_string(ptr(item))),
                  let node = self.model.store?.node(id: id) else { return }
            cell.nodeID = id
            bind(cell, node, row)
        }
        // The column takes the factory's reference; the view refs the column.
        let column = gtk_column_view_column_new(id.title, ptr(factory))
        gtk_column_view_column_set_expand(column, gbool(expand))
        gtk_column_view_column_set_resizable(column, gbool(true))
        if let fixedWidth {
            gtk_column_view_column_set_fixed_width(column, Int32(fixedWidth))
        }
        gtk_column_view_append_column(ptr(columnView), column)
        g_object_unref(raw(column))
        columns[id] = raw(column)!
    }

    // MARK: - Column layout

    /// Right-clicking any header lists the columns that can hide, checked when shown.
    private func installColumnMenu() {
        let group = raw(g_simple_action_group_new())!
        let menu = raw(g_menu_new())!
        for id in OutlineColumn.allCases where id != .name {
            guard let action = raw(g_simple_action_new_stateful("show-\(id.rawValue)", nil, g_variant_new_boolean(gbool(true)))) else {
                continue
            }
            connectPointer(action, "change-state") { [unowned self] variant in
                guard let variant else { return }
                var updated = self.layout
                updated.setHidden(id, g_variant_get_boolean(ptr(variant)) == 0)
                self.commitLayout(updated)
            }
            g_action_map_add_action(ptr(group), ptr(action))
            g_object_unref(action)
            columnActions[id] = action
            g_menu_append(ptr(menu), id.title, "outline.show-\(id.rawValue)")
        }
        gtk_widget_insert_action_group(ptr(columnView), "outline", ptr(group))
        g_object_unref(group)
        for column in columns.values {
            gtk_column_view_column_set_header_menu(ptr(column), ptr(menu))
        }
        g_object_unref(menu)
    }

    /// Narrow windows drop the secondary columns; the user's layout comes back when there's room.
    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        applyLayout(layout)
    }

    private func commitLayout(_ updated: ItemLayout<OutlineColumn>) {
        applyLayout(updated)
        model.preferences.outlineColumns = updated.isStandard ? "" : updated.stored
    }

    private func applyLayout(_ updated: ItemLayout<OutlineColumn>) {
        layout = updated
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        for (index, id) in updated.order.enumerated() {
            guard let column = columns[id] else { continue }
            if columnOrder().firstIndex(of: id) != index {
                // Repositions a column the view already holds.
                gtk_column_view_insert_column(ptr(columnView), guint(index), ptr(column))
            }
            let shown = !updated.isHidden(id) && !(isCompact && id.isSecondary)
            gtk_column_view_column_set_visible(ptr(column), gbool(shown))
        }
        for (id, action) in columnActions {
            g_simple_action_set_state(ptr(action), g_variant_new_boolean(gbool(!updated.isHidden(id))))
            // The last shown column can't hide.
            setActionEnabled(action, updated.isHidden(id) || updated.canHide(id))
        }
    }

    private func columnOrder() -> [OutlineColumn] {
        guard let list = gtk_column_view_get_columns(ptr(columnView)) else { return [] }
        return (0..<g_list_model_get_n_items(list)).compactMap { index -> OutlineColumn? in
            guard let item = g_list_model_get_item(list, index) else { return nil }
            defer { g_object_unref(item) }
            return columns.first { $0.value == item }?.key
        }
    }

    /// A header drag landed. GTK moves a column as a removal then an insertion, so the order is read once both
    /// are in; a drag that put another column before Name puts Name back.
    private func columnsDidMove() {
        guard !isApplyingLayout else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let order = self.columnOrder()
            guard order.count == self.columns.count, order != self.layout.order else { return }
            let stored = order.map { self.layout.isHidden($0) ? "-" + $0.rawValue : $0.rawValue }.joined(separator: ",")
            self.commitLayout(ItemLayout(stored: stored, pinned: .name))
        }
    }

    private static func setupName() -> Cell {
        let icon = Widgets.image("folder-symbolic")
        let label = Widgets.label("")
        gtk_label_set_ellipsize(ptr(label), PANGO_ELLIPSIZE_END)
        let content = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, [icon, label])
        let expander = raw(gtk_tree_expander_new())!
        gtk_tree_expander_set_child(ptr(expander), ptr(content))
        let cell = Cell(root: expander)
        cell.icon = icon
        cell.label = label
        cell.expander = expander
        return cell
    }

    private static func setupRightAligned() -> Cell {
        let label = Widgets.label("", xalign: 1, classes: ["neodisk-numeric"])
        let cell = Cell(root: label)
        cell.label = label
        return cell
    }

    private static func setupShare() -> Cell {
        let bar = raw(gtk_level_bar_new())!
        gtk_level_bar_remove_offset_value(ptr(bar), GTK_LEVEL_BAR_OFFSET_LOW)
        gtk_level_bar_remove_offset_value(ptr(bar), GTK_LEVEL_BAR_OFFSET_HIGH)
        gtk_level_bar_remove_offset_value(ptr(bar), GTK_LEVEL_BAR_OFFSET_FULL)
        gtk_level_bar_add_offset_value(ptr(bar), "neodisk-used", 1.0)
        Widgets.addClasses(bar, ["neodisk-capacity"])
        gtk_widget_set_hexpand(ptr(bar), gbool(true))
        gtk_widget_set_valign(ptr(bar), GTK_ALIGN_CENTER)
        let label = Widgets.label("", xalign: 1, classes: ["neodisk-numeric", "dim-label", "neodisk-caption"])
        gtk_widget_set_size_request(ptr(label), 44, -1)
        let root = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, [bar, label])
        let cell = Cell(root: root)
        cell.bar = bar
        cell.label = label
        return cell
    }

    private func bindName(_ cell: Cell, node: FileNodeRecord, row: GPtr) {
        gtk_tree_expander_set_list_row(ptr(cell.expander), ptr(row))
        gtk_label_set_text(ptr(cell.label), node.name)
        gtk_image_set_from_icon_name(ptr(cell.icon), Self.iconName(for: node))
        gtk_widget_set_opacity(ptr(cell.root), node.isSelfAccessible ? 1 : 0.55)
    }

    private func bindShare(_ cell: Cell, node: FileNodeRecord) {
        let parentSize = model.store?.parent(of: node.id)?.allocatedSize ?? node.allocatedSize
        let fraction = parentSize > 0 ? Double(node.allocatedSize) / Double(parentSize) : 0
        gtk_level_bar_set_value(ptr(cell.bar), min(1, max(0, fraction)))
        gtk_label_set_text(ptr(cell.label), fraction.formatted(.percent.precision(.fractionLength(0))))
    }

    /// Adwaita symbolic icon per kind category, the Linux counterpart of the
    /// Mac's SF Symbols in `FileKindClassifier.categorySymbol`.
    static func iconName(for node: FileNodeRecord) -> String {
        if node.isSymbolicLink { return "insert-link-symbolic" }
        if node.isDirectory && !FileKindClassifier.isLeafLike(node) { return "folder-symbolic" }
        switch FileKindClassifier.kindID(for: node, mode: .categories) {
        case "cat-video": return "video-x-generic-symbolic"
        case "cat-image": return "image-x-generic-symbolic"
        case "cat-audio": return "audio-x-generic-symbolic"
        case "cat-docs": return "x-office-document-symbolic"
        case "cat-archive": return "package-x-generic-symbolic"
        case "cat-backups": return "document-open-recent-symbolic"
        case "cat-code": return "utilities-terminal-symbolic"
        case "cat-data": return "drive-multidisk-symbolic"
        case "cat-3d": return "applications-engineering-symbolic"
        case "cat-games": return "applications-games-symbolic"
        case "cat-apps": return "application-x-executable-symbolic"
        case "cat-summarized": return "folder-symbolic"
        default: return "text-x-generic-symbolic"
        }
    }

    // MARK: - Model

    /// Rebuilds at once for a new tree or focus; while a scan streams
    /// partial trees, at most every couple of seconds.
    private func scheduleRebuild() {
        guard model.store != nil, let rootID = model.focusedRootID else {
            rebuildTask?.cancel()
            setModel(nil)
            builtFor = nil
            return
        }
        if let builtFor, builtFor.generation == model.storeGeneration, builtFor.rootID == rootID { return }
        let streaming = model.phase == .scanning
        let wait = streaming ? max(.zero, .seconds(2) - (ContinuousClock.now - lastRebuild)) : .zero
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if wait > .zero {
                guard (try? await Task.sleep(for: wait)) != nil else { return }
            }
            guard let self, let store = self.model.store, let focused = self.model.focusedRootID else { return }
            self.rebuild(store: store, rootID: store.node(id: focused) == nil ? store.rootID : focused)
        }
    }

    private func rebuild(store: FileTreeStore, rootID: String) {
        builtFor = (model.storeGeneration, rootID)
        lastRebuild = ContinuousClock.now
        guard let rootStore = Self.makeChildStore(for: rootID, in: store) else {
            setModel(nil)
            return
        }
        // gtk_tree_list_model_new takes ownership of one root reference.
        g_object_ref(rootStore.pointer)
        let context = Unmanaged.passRetained(OutlineChildren(model: model)).toOpaque()
        let tree = gtk_tree_list_model_new(
            ptr(rootStore.pointer),
            gbool(false),
            gbool(false),
            { item, data in
                nonisolated(unsafe) let item = item
                nonisolated(unsafe) let data = data
                nonisolated(unsafe) var children: OpaquePointer?
                MainActor.assumeIsolated {
                    guard let item, let data,
                          let id = string(from: gtk_string_object_get_string(ptr(item))) else { return }
                    let context = Unmanaged<OutlineChildren>.fromOpaque(data).takeUnretainedValue()
                    guard let store = context.model?.store,
                          let childStore = OutlineView.makeChildStore(for: id, in: store) else { return }
                    // Transfer full: the tree list model owns what we return.
                    g_object_ref(childStore.pointer)
                    children = ptr(childStore.pointer)
                }
                return children
            },
            context,
            { data in
                guard let data else { return }
                Unmanaged<OutlineChildren>.fromOpaque(data).release()
            }
        )
        setModel(tree.map { GObjectRef(adopting: raw($0)!) })
        syncSelection()
    }

    /// Children of `id` as a GListStore of GtkStringObjects (node IDs), in
    /// the tree store's order; nil for files and empty folders.
    static func makeChildStore(for id: String, in store: FileTreeStore) -> GObjectRef? {
        guard store.containsChildren(id: id) else { return nil }
        let children = store.children(of: id)
        guard !children.isEmpty else { return nil }
        let list = raw(g_list_store_new(gtk_string_object_get_type()))!
        var items: [gpointer?] = children.map { raw(gtk_string_object_new($0.id)) }
        items.withUnsafeMutableBufferPointer { buffer in
            g_list_store_splice(ptr(list), 0, 0, buffer.baseAddress, guint(buffer.count))
        }
        for item in items { g_object_unref(item) }
        return GObjectRef(adopting: list)
    }

    private func setModel(_ tree: GObjectRef?) {
        treeModel = tree
        guard let tree else {
            gtk_column_view_set_model(ptr(columnView), nil)
            selection = nil
            return
        }
        // gtk_multi_selection_new takes ownership of one model reference. Ctrl- and Shift-click and Ctrl+A
        // pick several rows.
        g_object_ref(tree.pointer)
        let multi = raw(gtk_multi_selection_new(ptr(tree.pointer)))!
        selection = GObjectRef(adopting: multi)
        gtk_column_view_set_model(ptr(columnView), ptr(multi))
        connectSelectionChanged(multi) { [unowned self] in
            guard !self.isSyncingSelection else { return }
            self.rowsDidChange()
        }
    }

    private static func extends(_ state: UInt32) -> Bool {
        state & (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue) != 0
    }

    private var rowCount: UInt32 {
        treeModel.map { g_list_model_get_n_items(ptr($0.pointer)) } ?? 0
    }

    private func id(atPosition position: UInt32) -> String? {
        guard let tree = treeModel,
              let row = gtk_tree_list_model_get_row(ptr(tree.pointer), position) else { return nil }
        defer { g_object_unref(raw(row)) }
        guard let item = gtk_tree_list_row_get_item(row) else { return nil }
        defer { g_object_unref(item) }
        return string(from: gtk_string_object_get_string(ptr(item)))
    }

    /// The user's rows become the model's selection.
    private func rowsDidChange() {
        guard let selection else { return }
        let bitset = gtk_selection_model_get_selection(ptr(selection.pointer))
        defer { gtk_bitset_unref(bitset) }
        var picked: [String] = []
        for index in 0..<gtk_bitset_get_size(bitset) {
            if let id = id(atPosition: gtk_bitset_get_nth(bitset, guint(index))) { picked.append(id) }
        }
        // Only an extending gesture needs to know what the outline shows (it keeps the rest).
        var shown = Set<String>()
        if isExtending {
            for position in 0..<rowCount {
                if let id = id(atPosition: position) { shown.insert(id) }
            }
        }
        isSyncingSelection = true
        model.select(fromList: picked, extending: isExtending) { shown.contains($0) }
        isSyncingSelection = false
    }

    /// The model's selection becomes the rows: the primary item revealed (ancestors expanded, scrolled to),
    /// the others highlighted where their rows are showing.
    private func syncSelection() {
        guard !isSyncingSelection, let selection else { return }
        let primary = reveal(model.selectedNodeID)
        let wanted = model.selection
        let selected = gtk_bitset_new_empty()
        if wanted.isMultiple {
            for position in 0..<rowCount {
                if let id = id(atPosition: position), wanted.contains(id) { gtk_bitset_add(selected, position) }
            }
        } else if let primary {
            gtk_bitset_add(selected, primary)
        }
        let mask = gtk_bitset_new_range(0, rowCount)
        isSyncingSelection = true
        gtk_selection_model_set_selection(ptr(selection.pointer), selected, mask)
        isSyncingSelection = false
        gtk_bitset_unref(selected)
        gtk_bitset_unref(mask)
    }

    private func node(atPosition position: UInt32) -> FileNodeRecord? {
        guard let tree = treeModel,
              let row = gtk_tree_list_model_get_row(ptr(tree.pointer), position) else { return nil }
        defer { g_object_unref(raw(row)) }
        guard let item = gtk_tree_list_row_get_item(row) else { return nil }
        defer { g_object_unref(item) }
        guard let id = string(from: gtk_string_object_get_string(ptr(item))) else { return nil }
        return model.store?.node(id: id)
    }

    /// Expands the outline down to `nodeID` and scrolls its row into view; its position, or nil when the
    /// outline doesn't hold it.
    private func reveal(_ nodeID: String?) -> UInt32? {
        guard let tree = treeModel, let nodeID, let store = model.store, let rootID = builtFor?.rootID,
              nodeID != rootID, store.isAncestor(rootID, of: nodeID) else { return nil }
        let chain = store.path(to: nodeID).drop { $0.id != rootID }.dropFirst()
        var row: OpaquePointer?
        var parentID = rootID
        for node in chain {
            guard let index = store.children(of: parentID).firstIndex(where: { $0.id == node.id }) else { break }
            let next: OpaquePointer?
            if let row {
                gtk_tree_list_row_set_expanded(row, gbool(true))
                next = gtk_tree_list_row_get_child_row(row, guint(index))
                g_object_unref(raw(row))
            } else {
                next = gtk_tree_list_model_get_child_row(ptr(tree.pointer), guint(index))
            }
            guard let next else { return nil }
            row = next
            parentID = node.id
        }
        guard let row else { return nil }
        let position = gtk_tree_list_row_get_position(row)
        g_object_unref(raw(row))
        gtk_column_view_scroll_to(ptr(columnView), position, nil, GTK_LIST_SCROLL_NONE, nil)
        return position
    }

    // MARK: - Context menu

    private func addContextGesture(to cell: Cell) {
        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self, unowned cell] _, x, y in
            guard let id = cell.nodeID else { return }
            // The menu acts on the selection: a row outside it becomes it (GNOME's rule).
            if !self.model.selection.contains(id) { self.model.select(id) }
            var point = graphene_point_t(x: Float(x), y: Float(y))
            var local = graphene_point_t()
            guard gtk_widget_compute_point(ptr(cell.root), ptr(self.columnView), &point, &local) != 0 else { return }
            self.showContextMenu(at: CGPoint(x: Double(local.x), y: Double(local.y)))
        }
        gtk_widget_add_controller(ptr(cell.root), ptr(click))
    }

    private func showContextMenu(at point: CGPoint) {
        let copy = model.selection.isMultiple ? L("Copy Paths") : L("Copy Path")
        Widgets.popupMenu(&contextMenu, sections: [
            [(L("Open"), "win.open-item"), (L("Show in Files"), "win.show-in-files"), (copy, "win.copy-path")],
            [(L("Zoom In"), "win.focus-in")],
            [(L("Move to Trash…"), "win.move-to-trash")],
        ], on: columnView, at: point)
    }
}

/// The file list's columns. Name stays first; the rest reorder by dragging their headers and hide from the
/// headers' menu.
enum OutlineColumn: String, CaseIterable {
    case name, size, share, files, modified

    var title: String {
        switch self {
        case .name: L("Name")
        case .size: L("Size")
        case .share: L("Share")
        case .files: L("Files")
        case .modified: L("Modified")
        }
    }

    /// What a narrow window drops first, so Name keeps its room.
    var isSecondary: Bool { self == .files || self == .modified }
}

/// The tree list model's child-model callback context: a weak route back
/// to the model, whose store may have moved on since the tree was built.
private final class OutlineChildren {
    weak var model: AppModel?
    init(model: AppModel) { self.model = model }
}
