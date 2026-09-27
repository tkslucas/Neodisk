//
//  OutlineView.swift
//  NeodiskGTK
//
//  The file outline: GtkColumnView over a GtkTreeListModel, rooted at the
//  folder the visualizations show. Child rows are created only when a folder
//  is expanded (a million-node scan never materializes a million list
//  items), in the tree store's size order, like the Mac's outline.
//  Selection syncs both ways with the treemap: picking a cell expands the
//  outline down to it and scrolls it into view.
//

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
    private var contextMenu: GPtr?
    /// Columns a narrow window drops first, so Name keeps its room.
    private(set) var secondaryColumns: [GPtr] = []
    private var tokens: [ObservationToken] = []

    private static let cellKey = "neodisk-outline-cell"

    init(model: AppModel) {
        self.model = model
        columnView = raw(gtk_column_view_new(nil))!
        Widgets.addClasses(columnView, ["data-table"])
        gtk_column_view_set_reorderable(ptr(columnView), gbool(false))

        let scrolled = Widgets.scrolled(columnView, horizontalPolicy: GTK_POLICY_AUTOMATIC)
        gtk_widget_set_size_request(ptr(scrolled), -1, 140)
        widget = scrolled
        attach(self, to: widget, key: "neodisk-outline")

        addColumn(L("Name"), expand: true, setup: Self.setupName, bind: { [unowned self] cell, node, row in
            self.bindName(cell, node: node, row: row)
        })
        addColumn(L("Size"), fixedWidth: 96, setup: Self.setupRightAligned, bind: { cell, node, _ in
            gtk_label_set_text(ptr(cell.label), NeodiskFormatters.size(node.allocatedSize))
        })
        addColumn(L("Share"), fixedWidth: 120, setup: Self.setupShare, bind: { [unowned self] cell, node, _ in
            self.bindShare(cell, node: node)
        })
        let files = addColumn(L("Files"), fixedWidth: 84, setup: Self.setupRightAligned, bind: { cell, node, _ in
            gtk_label_set_text(ptr(cell.label), node.isDirectory ? node.descendantFileCount.formatted() : "")
        })
        let modified = addColumn(L("Modified"), fixedWidth: 130, setup: Self.setupRightAligned, bind: { cell, node, _ in
            // An mtime of 0 (the epoch) means the filesystem doesn't track it.
            let text = node.lastModified.flatMap { $0.timeIntervalSince1970 > 0 ? $0.formatted(date: .abbreviated, time: .omitted) : nil } ?? ""
            gtk_label_set_text(ptr(cell.label), text)
        })
        secondaryColumns = [files, modified]

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
            self.reveal(self.model.selectedNodeID)
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

    @discardableResult
    private func addColumn(_ title: String, expand: Bool = false, fixedWidth: Int? = nil, setup: @escaping Setup, bind: @escaping Bind) -> GPtr {
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
        let column = gtk_column_view_column_new(title, ptr(factory))
        gtk_column_view_column_set_expand(column, gbool(expand))
        gtk_column_view_column_set_resizable(column, gbool(true))
        if let fixedWidth {
            gtk_column_view_column_set_fixed_width(column, Int32(fixedWidth))
        }
        gtk_column_view_append_column(ptr(columnView), column)
        g_object_unref(raw(column))
        return raw(column)!
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
        case "cat-code": return "utilities-terminal-symbolic"
        case "cat-data": return "drive-multidisk-symbolic"
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
        reveal(model.selectedNodeID)
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
        // gtk_single_selection_new takes ownership of one model reference.
        g_object_ref(tree.pointer)
        let single = raw(gtk_single_selection_new(ptr(tree.pointer)))!
        gtk_single_selection_set_autoselect(ptr(single), gbool(false))
        gtk_single_selection_set_can_unselect(ptr(single), gbool(true))
        gtk_single_selection_set_selected(ptr(single), neodisk_invalid_list_position())
        selection = GObjectRef(adopting: single)
        gtk_column_view_set_model(ptr(columnView), ptr(single))
        connectSelectionChanged(single) { [unowned self] in
            guard !self.isSyncingSelection else { return }
            let position = gtk_single_selection_get_selected(ptr(single))
            guard position != neodisk_invalid_list_position(), let node = self.node(atPosition: position) else { return }
            self.isSyncingSelection = true
            self.model.select(node.id)
            self.isSyncingSelection = false
        }
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

    /// Expands the outline down to `nodeID`, selects its row, and scrolls
    /// it into view.
    private func reveal(_ nodeID: String?) {
        guard !isSyncingSelection, let selection, let tree = treeModel else { return }
        guard let nodeID, let store = model.store, let rootID = builtFor?.rootID,
              nodeID != rootID, store.isAncestor(rootID, of: nodeID) else {
            isSyncingSelection = true
            gtk_single_selection_set_selected(ptr(selection.pointer), neodisk_invalid_list_position())
            isSyncingSelection = false
            return
        }
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
            guard let next else { return }
            row = next
            parentID = node.id
        }
        guard let row else { return }
        let position = gtk_tree_list_row_get_position(row)
        g_object_unref(raw(row))
        isSyncingSelection = true
        gtk_single_selection_set_selected(ptr(selection.pointer), position)
        isSyncingSelection = false
        gtk_column_view_scroll_to(ptr(columnView), position, nil, GTK_LIST_SCROLL_NONE, nil)
    }

    // MARK: - Context menu

    private func addContextGesture(to cell: Cell) {
        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self, unowned cell] _, x, y in
            guard let id = cell.nodeID else { return }
            self.model.select(id)
            var point = graphene_point_t(x: Float(x), y: Float(y))
            var local = graphene_point_t()
            guard gtk_widget_compute_point(ptr(cell.root), ptr(self.columnView), &point, &local) != 0 else { return }
            self.showContextMenu(at: CGPoint(x: Double(local.x), y: Double(local.y)))
        }
        gtk_widget_add_controller(ptr(cell.root), ptr(click))
    }

    private func showContextMenu(at point: CGPoint) {
        Widgets.popupMenu(&contextMenu, sections: [
            [(L("Open"), "win.open-item"), (L("Show in Files"), "win.show-in-files"), (L("Copy Path"), "win.copy-path")],
            [(L("Zoom In"), "win.focus-in")],
        ], on: columnView, at: point)
    }
}

/// The tree list model's child-model callback context: a weak route back
/// to the model, whose store may have moved on since the tree was built.
private final class OutlineChildren {
    weak var model: AppModel?
    init(model: AppModel) { self.model = model }
}
