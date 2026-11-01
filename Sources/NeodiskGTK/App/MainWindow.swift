// libadwaita overlay split view: locations sidebar on the left, workspace on the right,
// mirroring the Mac layout and header bar.

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class MainWindow {
    let window: GPtr
    let model: AppModel

    private let splitView: GPtr
    private let toastOverlay: GPtr
    private let restoreLabel: GPtr
    private let titleLabel: GPtr
    private let subtitleLabel: GPtr
    private let contentStack: GPtr
    private let vizStack: GPtr
    private let statisticsSplit: GPtr
    private let vizPaned: GPtr
    private let scanButton: GPtr
    private let stopButton: GPtr
    private let viewToggles: [VizView: GPtr]
    private let vizSwitcher: GPtr
    /// "views.<view>" checkboxes: which toggles the header shows.
    private let viewActions = GObjectRef(adopting: raw(g_simple_action_group_new())!)
    private let viewsMenu: GObjectRef
    private var viewsPopover: GPtr?
    private let menuButton: GPtr

    private let sidebar: SidebarView
    private let treemap: TreemapView
    private let sunburst: SunburstView
    private let outline: OutlineView
    private let statistics: StatisticsView
    private let progress: ScanProgressView
    private let statusBar: StatusBar
    private let breadcrumbs: BreadcrumbBar
    private let search: OutlineSearch

    private var actions: [String: GPtr] = [:]
    /// Kept while it's out of the window (turned off in Preferences), so it can come back.
    private var trashAction: GObjectRef?
    /// The moves the toast on screen reports. Another move while it shows adds to it, rather than queuing a
    /// second toast behind it.
    private var movedToast: (toast: GObjectRef, count: Int, bytes: Int64)?
    private var tokens: [ObservationToken] = []

    init(application: GPtr, model: AppModel) {
        self.model = model
        let preferences = model.preferences

        window = raw(adw_application_window_new(ptr(application)))!
        gtk_window_set_default_size(ptr(window), Int32(preferences.windowWidth), Int32(preferences.windowHeight))
        // Breakpoints need a floor to collapse the layout against.
        gtk_widget_set_size_request(ptr(window), 640, 480)
        gtk_window_set_title(ptr(window), AppChannel.current.appName)

        sidebar = SidebarView(model: model)
        treemap = TreemapView(model: model)
        sunburst = SunburstView(model: model)
        outline = OutlineView(model: model)
        statistics = StatisticsView(model: model)
        progress = ScanProgressView(model: model)
        statusBar = StatusBar(model: model)
        breadcrumbs = BreadcrumbBar(model: model)
        search = OutlineSearch(model: model, outline: outline.widget)

        // Sidebar pane: its own header bar, like GNOME Files.
        let sidebarToolbar = raw(adw_toolbar_view_new())!
        let sidebarHeader = raw(adw_header_bar_new())!
        let sidebarTitle = raw(adw_window_title_new(AppChannel.current.appName, nil))!
        adw_header_bar_set_title_widget(ptr(sidebarHeader), ptr(sidebarTitle))
        menuButton = raw(gtk_menu_button_new())!
        gtk_menu_button_set_icon_name(ptr(menuButton), "open-menu-symbolic")
        gtk_widget_set_tooltip_text(ptr(menuButton), L("Main Menu"))
        // The views stay here as the way back: picking a hidden one shows its toggle again.
        let layoutSection = Widgets.section([])
        g_menu_append_submenu(ptr(layoutSection.pointer), L("Sidebar Sections"), ptr(sidebar.sectionsMenu.pointer))
        g_menu_append(ptr(layoutSection.pointer), L("Show Status Bar"), "win.show-status-bar")
        let primaryMenu = Widgets.menu(sections: [
            Widgets.section([(L("Choose Folder…"), "win.open-folder")]),
            Widgets.section(VizView.allCases.map { ($0.menuTitle, "win.view::\($0.rawValue)") }),
            layoutSection,
            Widgets.section([(L("Preferences"), "app.preferences"), (L("Keyboard Shortcuts"), "win.show-help-overlay"), (L("About %@", AppChannel.current.appName), "app.about")]),
            Widgets.section([(L("Quit"), "app.quit")]),
        ])
        gtk_menu_button_set_menu_model(ptr(menuButton), ptr(primaryMenu.pointer))
        gtk_menu_button_set_primary(ptr(menuButton), gbool(true))
        adw_header_bar_pack_end(ptr(sidebarHeader), ptr(menuButton))
        adw_toolbar_view_add_top_bar(ptr(sidebarToolbar), ptr(sidebarHeader))
        adw_toolbar_view_set_content(ptr(sidebarToolbar), ptr(sidebar.widget))

        // Workspace header, laid out like the Mac toolbar: the scan title
        // on the left, the view switcher in the middle, actions on the right.
        let header = raw(adw_header_bar_new())!

        let sidebarToggle = raw(gtk_toggle_button_new())!
        gtk_button_set_icon_name(ptr(sidebarToggle), "sidebar-show-symbolic")
        gtk_widget_set_tooltip_text(ptr(sidebarToggle), L("Toggle Sidebar"))
        adw_header_bar_pack_start(ptr(header), ptr(sidebarToggle))
        titleLabel = Widgets.label(AppChannel.current.appName, classes: ["heading"])
        gtk_label_set_ellipsize(ptr(titleLabel), PANGO_ELLIPSIZE_END)
        subtitleLabel = Widgets.label("", classes: ["dim-label", "neodisk-caption", "neodisk-numeric"])
        gtk_label_set_ellipsize(ptr(subtitleLabel), PANGO_ELLIPSIZE_END)
        let titleBox = Widgets.box(GTK_ORIENTATION_VERTICAL, [titleLabel, subtitleLabel])
        gtk_widget_set_valign(ptr(titleBox), GTK_ALIGN_CENTER)
        Widgets.setMargins(titleBox, start: 6)
        adw_header_bar_pack_start(ptr(header), ptr(titleBox))

        var viewToggles: [VizView: GPtr] = [:]
        for view in VizView.allCases {
            let toggle = raw(gtk_toggle_button_new())!
            gtk_button_set_icon_name(ptr(toggle), view.iconName)
            gtk_widget_set_tooltip_text(ptr(toggle), view.menuTitle)
            gtk_toggle_button_set_group(ptr(toggle), ptr(viewToggles.values.first))
            viewToggles[view] = toggle
        }
        self.viewToggles = viewToggles
        viewsMenu = Widgets.menu([VizView.allCases.map { ($0.menuTitle, "views.\($0.rawValue)") }])
        vizSwitcher = Widgets.box(GTK_ORIENTATION_HORIZONTAL, classes: ["linked"], VizView.allCases.compactMap { viewToggles[$0] })
        adw_header_bar_set_title_widget(ptr(header), ptr(vizSwitcher))

        scanButton = Widgets.iconButton("view-refresh-symbolic", tooltip: L("Rescan"), action: "win.rescan")
        stopButton = Widgets.iconButton("process-stop-symbolic", tooltip: L("Stop Scan"), action: "win.stop")
        let statisticsToggle = raw(gtk_toggle_button_new())!
        gtk_button_set_icon_name(ptr(statisticsToggle), "sidebar-show-right-symbolic")
        gtk_widget_set_tooltip_text(ptr(statisticsToggle), L("Statistics"))
        adw_header_bar_pack_end(ptr(header), ptr(statisticsToggle))
        adw_header_bar_pack_end(ptr(header), ptr(stopButton))
        adw_header_bar_pack_end(ptr(header), ptr(scanButton))

        // Workspace content.
        vizStack = raw(gtk_stack_new())!
        gtk_stack_set_transition_type(ptr(vizStack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_add_named(ptr(vizStack), ptr(treemap.widget), "treemap")
        gtk_stack_add_named(ptr(vizStack), ptr(sunburst.widget), "sunburst")
        let vizColumn = Widgets.box(GTK_ORIENTATION_VERTICAL, [breadcrumbs.widget, vizStack])

        vizPaned = raw(gtk_paned_new(GTK_ORIENTATION_VERTICAL))!
        gtk_paned_set_start_child(ptr(vizPaned), ptr(vizColumn))
        gtk_paned_set_end_child(ptr(vizPaned), ptr(search.widget))
        gtk_paned_set_resize_end_child(ptr(vizPaned), gbool(false))
        gtk_paned_set_shrink_end_child(ptr(vizPaned), gbool(false))
        gtk_paned_set_position(ptr(vizPaned), Int32(max(320, preferences.windowHeight - 380)))

        // Pinned: only the Statistics toggle shows or hides it, never a window resize.
        statisticsSplit = raw(adw_overlay_split_view_new())!
        adw_overlay_split_view_set_sidebar_position(ptr(statisticsSplit), GTK_PACK_END)
        adw_overlay_split_view_set_content(ptr(statisticsSplit), ptr(vizPaned))
        adw_overlay_split_view_set_sidebar(ptr(statisticsSplit), ptr(statistics.widget))
        adw_overlay_split_view_set_pin_sidebar(ptr(statisticsSplit), gbool(true))
        adw_overlay_split_view_set_min_sidebar_width(ptr(statisticsSplit), 330)
        adw_overlay_split_view_set_max_sidebar_width(ptr(statisticsSplit), 380)
        adw_overlay_split_view_set_sidebar_width_fraction(ptr(statisticsSplit), 0.28)
        adw_overlay_split_view_set_show_sidebar(ptr(statisticsSplit), gbool(preferences.showsStatistics))

        let emptyState = raw(adw_status_page_new())!
        adw_status_page_set_icon_name(ptr(emptyState), "drive-harddisk-symbolic")
        adw_status_page_set_title(ptr(emptyState), L("Choose a Location to Scan"))
        adw_status_page_set_description(
            ptr(emptyState),
            L("Scan folders and disks to see where space is going,\nthen clear out what you don't need.")
        )
        let openButton = raw(gtk_button_new_with_label(L("Choose Folder…")))!
        Widgets.addClasses(openButton, ["pill", "suggested-action"])
        gtk_widget_set_halign(ptr(openButton), GTK_ALIGN_CENTER)
        gtk_actionable_set_action_name(ptr(openButton), "win.open-folder")
        adw_status_page_set_child(ptr(emptyState), ptr(openButton))

        // A saved scan decoding (about a second per million files) says so rather than showing an empty
        // workspace.
        let spinner = raw(gtk_spinner_new())!
        gtk_spinner_start(ptr(spinner))
        gtk_widget_set_size_request(ptr(spinner), 32, 32)
        restoreLabel = Widgets.label("", xalign: 0.5, classes: ["title-4", "dim-label"], wrap: true)
        gtk_label_set_justify(ptr(restoreLabel), GTK_JUSTIFY_CENTER)
        let restoreState = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 14, [spinner, restoreLabel])
        gtk_widget_set_valign(ptr(restoreState), GTK_ALIGN_CENTER)
        gtk_widget_set_halign(ptr(restoreState), GTK_ALIGN_CENTER)
        Widgets.setMargins(restoreState, all: 24)

        contentStack = raw(gtk_stack_new())!
        gtk_stack_set_transition_type(ptr(contentStack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_add_named(ptr(contentStack), ptr(emptyState), "empty")
        gtk_stack_add_named(ptr(contentStack), ptr(restoreState), "restoring")
        gtk_stack_add_named(ptr(contentStack), ptr(statisticsSplit), "workspace")

        let workspaceToolbar = raw(adw_toolbar_view_new())!
        adw_toolbar_view_add_top_bar(ptr(workspaceToolbar), ptr(header))
        adw_toolbar_view_add_top_bar(ptr(workspaceToolbar), ptr(progress.widget))
        adw_toolbar_view_set_content(ptr(workspaceToolbar), ptr(contentStack))
        adw_toolbar_view_add_bottom_bar(ptr(workspaceToolbar), ptr(statusBar.widget))

        splitView = raw(adw_overlay_split_view_new())!
        adw_overlay_split_view_set_sidebar(ptr(splitView), ptr(sidebarToolbar))
        adw_overlay_split_view_set_content(ptr(splitView), ptr(workspaceToolbar))
        adw_overlay_split_view_set_min_sidebar_width(ptr(splitView), 220)
        adw_overlay_split_view_set_max_sidebar_width(ptr(splitView), 300)
        g_object_bind_property(
            splitView, "show-sidebar", sidebarToggle, "active",
            GBindingFlags(rawValue: 1 | 2)  // G_BINDING_BIDIRECTIONAL | G_BINDING_SYNC_CREATE
        )
        toastOverlay = raw(adw_toast_overlay_new())!
        adw_toast_overlay_set_child(ptr(toastOverlay), ptr(splitView))
        adw_application_window_set_content(ptr(window), ptr(toastOverlay))

        // Narrow windows: statistics float over the map and secondary outline columns give way to names; narrower
        // still, the sidebar becomes an overlay too. Only the last matching breakpoint applies, so the narrower one
        // comes last and repeats the wider one's changes.
        addBreakpoint("max-width: 900sp", collapsing: [statisticsSplit])
        addBreakpoint("max-width: 760sp", collapsing: [statisticsSplit, splitView])

        attach(self, to: window, key: Self.attachmentKey)
        gtk_widget_insert_action_group(ptr(window), "sidebar", ptr(sidebar.actions.pointer))
        gtk_widget_insert_action_group(ptr(window), "views", ptr(viewActions.pointer))
        installActions()
        bindModel()

        // Escape deselects wherever the focus is, once the focused widget (search, a zoomed map) passes on it.
        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, state in
            let modifiers = GDK_SHIFT_MASK.rawValue | GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue
            guard Int32(keyval) == GDK_KEY_Escape, state & modifiers == 0, !self.model.selection.isEmpty else {
                return false
            }
            self.model.select(nil)
            return true
        }
        gtk_widget_add_controller(ptr(window), ptr(keys))

        for (view, toggle) in viewToggles {
            connect(toggle, "toggled") { [unowned self] in
                if gtk_toggle_button_get_active(ptr(toggle)) != 0 { self.model.preferences.workspaceLayout.pick(view) }
            }
        }
        // Right-click: the checklist of views shown; the last one shown stays.
        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self] _, x, y in
            // Claimed, or the header's window handle opens the window manager's menu too.
            gtk_gesture_set_state(ptr(click), GTK_EVENT_SEQUENCE_CLAIMED)
            self.showViewMenu(at: CGPoint(x: x, y: y))
        }
        gtk_widget_add_controller(ptr(vizSwitcher), ptr(click))
        g_object_bind_property(
            statisticsSplit, "show-sidebar", statisticsToggle, "active",
            GBindingFlags(rawValue: 1 | 2)  // G_BINDING_BIDIRECTIONAL | G_BINDING_SYNC_CREATE
        )
        connectNotify(statisticsSplit, "show-sidebar") { [unowned self] in
            self.model.preferences.showsStatistics = adw_overlay_split_view_get_show_sidebar(ptr(self.statisticsSplit)) != 0
        }
        connectNotify(window, "default-width") { [unowned self] in self.rememberSize() }
        connectNotify(window, "default-height") { [unowned self] in self.rememberSize() }
    }

    private static let attachmentKey = "neodisk-main-window"

    private func addBreakpoint(_ conditionText: String, collapsing splitViews: [GPtr]) {
        guard let condition = adw_breakpoint_condition_parse(conditionText) else { return }
        let breakpoint = adw_breakpoint_new(condition)
        var collapsed = GValue()
        g_value_init(&collapsed, neodisk_boolean_type())
        g_value_set_boolean(&collapsed, gbool(true))
        for splitView in splitViews {
            adw_breakpoint_add_setter(breakpoint, ptr(splitView), "collapsed", &collapsed)
        }
        g_value_unset(&collapsed)
        // Not a setter: the user may hide or show columns meanwhile, and a setter would undo that on unapply.
        connect(raw(breakpoint), "apply") { [outline] in outline.setCompact(true) }
        connect(raw(breakpoint), "unapply") { [outline] in outline.setCompact(false) }
        adw_application_window_add_breakpoint(ptr(window), breakpoint)
    }

    private func showViewMenu(at point: CGPoint) {
        Widgets.popupMenu(&viewsPopover, model: viewsMenu, on: vizSwitcher, at: point)
    }

    /// NEODISK_POPUP: opens a menu for a screen grab (popovers aren't in the window's capture).
    func popUpForCapture(_ menu: String) {
        switch menu {
        case "primary": gtk_menu_button_popup(ptr(menuButton))
        case "sections": sidebar.showSectionsMenu(from: .volumes, at: CGPoint(x: 40, y: 8))
        case "status": statusBar.showMenu(at: CGPoint(x: 40, y: 8))
        case "views": showViewMenu(at: CGPoint(x: 20, y: 20))
        case "preferences": PreferencesDialog.present(model: model, from: window, onScanPage: true)
        default: break
        }
    }

    func present() {
        gtk_window_present(ptr(window))
    }

    private func rememberSize() {
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(ptr(window), &width, &height)
        if width > 0 { model.preferences.windowWidth = Int(width) }
        if height > 0 { model.preferences.windowHeight = Int(height) }
    }

    // MARK: - Model binding

    private func bindModel() {
        tokens.append(track { [unowned self] in
            _ = self.model.minuteTick
            let page = switch (self.model.target, self.model.phase) {
            case (nil, _): "empty"
            case (.some, .restoring): "restoring"
            default: "workspace"
            }
            gtk_stack_set_visible_child_name(ptr(self.contentStack), page)
            if let target = self.model.target {
                gtk_label_set_text(ptr(self.restoreLabel), L("Opening last scan of %@…", self.displayName(target)))
            }

            let title = self.model.target.map(self.displayName) ?? AppChannel.current.appName
            gtk_label_set_text(ptr(self.titleLabel), title)
            let subtitle = self.subtitle()
            gtk_label_set_text(ptr(self.subtitleLabel), subtitle ?? "")
            Widgets.setVisible(self.subtitleLabel, subtitle != nil)
            gtk_window_set_title(ptr(self.window), self.model.target == nil ? AppChannel.current.appName : "\(title) — \(AppChannel.current.appName)")

            let scanning = self.model.isScanning || self.model.phase == .restoring
            // Persistent controls that disable when unusable, never vanish
            // (a product rule shared with the Mac).
            setActionEnabled(self.actions["rescan"], self.model.target != nil && !scanning)
            setActionEnabled(self.actions["stop"], scanning)
            Widgets.setVisible(self.stopButton, scanning)
            Widgets.setVisible(self.scanButton, !scanning)
            setActionEnabled(self.actions["focus-out"], self.model.canFocusOut)
            setActionEnabled(self.actions["focus-back"], self.model.drillHistory.canGoBack)
            setActionEnabled(self.actions["focus-forward"], self.model.drillHistory.canGoForward)
            setActionEnabled(self.actions["search"], self.model.snapshot != nil)
            let hasSelection = self.model.selectedNode != nil
            for name in ["open-item", "show-in-files", "copy-path"] {
                setActionEnabled(self.actions[name], hasSelection)
            }
        })
        tokens.append(track { [unowned self] in
            // Several items: enabled while any can go; the confirmation then says which can't.
            let canMove = self.model.selectedNodes.contains { self.model.canMoveToTrash($0) }
            setActionEnabled(self.trashAction?.pointer, canMove)
        })
        tokens.append(track { [unowned self] in
            self.setTrashActionInstalled(self.model.preferences.allowsMovingToTrash)
        })
        tokens.append(track { [unowned self] in
            let layout = self.model.preferences.workspaceLayout
            gtk_stack_set_visible_child_name(ptr(self.vizStack), layout.mode == .sunburst ? "sunburst" : "treemap")
            for (view, toggle) in self.viewToggles {
                Widgets.setVisible(toggle, !layout.views.isHidden(view))
                setActionState(self.actions["views.\(view.rawValue)"], !layout.views.isHidden(view))
                setActionEnabled(self.actions["views.\(view.rawValue)"], layout.views.isHidden(view) || layout.views.canHide(view))
            }
            gtk_toggle_button_set_active(ptr(self.viewToggles[layout.view]), gbool(true))
            setActionState(self.actions["view"], layout.view.rawValue)
        })
        tokens.append(track { [unowned self] in
            setActionState(self.actions["show-status-bar"], self.model.preferences.showsStatusBar)
        })
        tokens.append(track { [unowned self] in
            let shows = gbool(self.model.preferences.showsStatistics)
            if adw_overlay_split_view_get_show_sidebar(ptr(self.statisticsSplit)) != shows {
                adw_overlay_split_view_set_show_sidebar(ptr(self.statisticsSplit), shows)
            }
        })
    }

    private func displayName(_ target: ScanTarget) -> String {
        target.id == "/" ? L("Computer") : target.displayName
    }

    private func subtitle() -> String? {
        switch model.phase {
        case .restoring:
            return L("Opening…")
        case .scanning:
            return L("Scanning…")
        case .failed(let message):
            return message
        case .idle:
            return nil
        case .displaying:
            guard let store = model.store else { return nil }
            var parts = [NeodiskFormatters.size(store.root.allocatedSize)]
            if let space = model.volumeSpace {
                parts.append(L("%@ free", NeodiskFormatters.size(space.availableCapacity)))
            }
            if model.isRefreshing {
                parts.append(L("Refreshing…"))
            } else if model.isShowingPartialScan {
                parts.append(L("Stopped — showing partial results"))
            } else if let snapshot = model.snapshot, let finished = snapshot.finishedAt {
                parts.append(L("Scanned %@", DisplayFormatters.relativeDate(finished)))
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Actions

    private func installActions() {
        let window = self.window
        actions["open-folder"] = addAction(to: window, "open-folder") { [unowned self] _ in
            self.chooseFolder()
        }
        actions["rescan"] = addAction(to: window, "rescan") { [unowned self] _ in
            self.model.rescan()
        }
        actions["stop"] = addAction(to: window, "stop") { [unowned self] _ in
            self.model.cancelScan()
        }
        actions["search"] = addAction(to: window, "search") { [unowned self] _ in
            self.search.focus()
        }
        actions["focus-in"] = addAction(to: window, "focus-in") { [unowned self] _ in
            if !self.model.drillIntoSelection() {
                gtk_widget_error_bell(ptr(self.window))
            }
        }
        actions["focus-out"] = addAction(to: window, "focus-out") { [unowned self] _ in
            self.model.focusOut()
        }
        actions["focus-back"] = addAction(to: window, "focus-back") { [unowned self] _ in
            if !self.model.focusBack() {
                gtk_widget_error_bell(ptr(self.window))
            }
        }
        actions["focus-forward"] = addAction(to: window, "focus-forward") { [unowned self] _ in
            if !self.model.focusForward() {
                gtk_widget_error_bell(ptr(self.window))
            }
        }
        actions["toggle-sidebar"] = addAction(to: window, "toggle-sidebar") { [unowned self] _ in
            let shown = adw_overlay_split_view_get_show_sidebar(ptr(self.splitView)) != 0
            adw_overlay_split_view_set_show_sidebar(ptr(self.splitView), gbool(!shown))
        }
        actions["show-status-bar"] = addToggleAction(to: window, "show-status-bar") { [unowned self] shown in
            self.model.preferences.showsStatusBar = shown
        }
        addAction(to: window, "hide-status-bar") { [unowned self] _ in
            self.model.preferences.showsStatusBar = false
        }
        let current = model.preferences.workspaceLayout.view.rawValue
        actions["view"] = addAction(to: window, "view", stringParameter: true, state: current) { [unowned self] value in
            guard let view = value.flatMap(VizView.init(rawValue:)) else { return }
            self.model.preferences.workspaceLayout.pick(view)
        }
        for view in VizView.allCases {
            actions["views.\(view.rawValue)"] = addToggleAction(to: viewActions.pointer, view.rawValue) { [unowned self] shown in
                self.model.preferences.workspaceLayout.setHidden(view, !shown)
            }
        }
        actions["open-item"] = addAction(to: window, "open-item") { [unowned self] _ in
            for node in self.model.selectedNodes { FileActions.open(node.path, from: self.window) }
        }
        actions["show-in-files"] = addAction(to: window, "show-in-files") { [unowned self] _ in
            guard let path = self.model.selectedNode?.path else { return }
            FileActions.showInFileManager(path, from: self.window)
        }
        actions["copy-path"] = addAction(to: window, "copy-path") { [unowned self] _ in
            let paths = self.model.selectedNodes.map(\.path)
            guard !paths.isEmpty else { return }
            FileActions.copyPath(paths.joined(separator: "\n"), from: self.window)
        }
        addAction(to: window, "open-trash") { [unowned self] _ in
            FileActions.openTrash(from: self.window)
        }
        if let action = addAction(to: window, "move-to-trash", { [unowned self] _ in
            self.moveSelectionToTrash()
        }) {
            trashAction = GObjectRef(retaining: action)
        }
        actions["scan-location"] = addAction(to: window, "scan-location", stringParameter: true) { [unowned self] path in
            guard let path else { return }
            self.model.open(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)))
        }
        addAction(to: window, "show-help-overlay") { [unowned self] _ in
            ShortcutsWindow.present(from: self.window)
        }
    }

    // MARK: - Moving to the Trash

    /// Off in Preferences, the action leaves the window and its menu items hide with it.
    private func setTrashActionInstalled(_ installed: Bool) {
        guard let action = trashAction?.pointer else { return }
        let isInstalled = g_action_map_lookup_action(ptr(window), "move-to-trash") != nil
        if installed, !isInstalled {
            g_action_map_add_action(ptr(window), ptr(action))
        } else if !installed, isInstalled {
            g_action_map_remove_action(ptr(window), "move-to-trash")
        }
    }

    /// Delete in the map or the outline. A plain key the focused view handles, not an app accelerator, which
    /// would take Delete from the search field. Shift+Delete means "delete for good" elsewhere: not here.
    static func handleTrashKey(_ keyval: UInt32, state: UInt32, from widget: GPtr?) -> Bool {
        let modifiers: UInt32 = 1 | 4 | 8  // GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_ALT_MASK
        guard Int32(keyval) == GDK_KEY_Delete || Int32(keyval) == GDK_KEY_KP_Delete, state & modifiers == 0,
              let root = raw(gtk_widget_get_root(ptr(widget))),
              let window = attached(MainWindow.self, to: root, key: attachmentKey) else { return false }
        window.moveSelectionToTrash()
        return true
    }

    /// Explains a refusal instead of doing nothing; otherwise asks, then moves. Several selected items go after
    /// one confirmation (a folder takes what's selected inside it); the ones that can't are named there.
    func moveSelectionToTrash() {
        guard let store = model.store, !model.selection.isEmpty, !model.isMovingToTrash else {
            gtk_widget_error_bell(ptr(window))
            return
        }
        if let reason = model.trashUnavailableReason {
            showToast(reason)
            return
        }
        let selected = model.selection.nodes(in: store)
        let (allowed, refusals) = store.trashSplit(selected, reasons: selected.map(model.trashRefusalReason))
        guard allowed.count + refusals.count > 1 else {
            if let node = allowed.first ?? selected.first { moveToTrash(node) }
            return
        }
        guard !allowed.isEmpty else {
            showAlert(heading: L("Can't Move %lld Items to the Trash", Int64(refusals.count)), body: refusals.first ?? "")
            return
        }
        let confirmation = TrashConfirmation(nodes: allowed, scannedAt: model.snapshot?.finishedAt)
        var message = confirmation.message
        if let firstRefusal = refusals.first {
            message += "\n\n" + TrashReport.refused(refusals.count, firstReason: firstRefusal)
        }
        confirm(title: confirmation.title, message: message) { [unowned self] in
            Task { await self.move(allowed) }
        }
    }

    private func moveToTrash(_ node: FileNodeRecord) {
        if let reason = model.trashRefusalReason(for: node) {
            showAlert(heading: L("Can't Move “%@” to the Trash", node.name), body: reason)
            return
        }
        let confirmation = TrashConfirmation(nodes: [node], scannedAt: model.snapshot?.finishedAt)
        confirm(title: confirmation.title, message: confirmation.message) { [unowned self] in
            Task { await self.move(node) }
        }
    }

    private func confirm(title: String, message: String, then move: @escaping @MainActor () -> Void) {
        let dialog = raw(adw_alert_dialog_new(title, message))!
        adw_alert_dialog_add_response(ptr(dialog), "cancel", L("Cancel"))
        adw_alert_dialog_add_response(ptr(dialog), "trash", L("Move to Trash"))
        adw_alert_dialog_set_response_appearance(ptr(dialog), "trash", ADW_RESPONSE_DESTRUCTIVE)
        // GNOME's rule for destructive responses: Return and Escape both cancel.
        adw_alert_dialog_set_default_response(ptr(dialog), "cancel")
        adw_alert_dialog_set_close_response(ptr(dialog), "cancel")
        connectPointer(dialog, "response") { response in
            guard string(from: response?.assumingMemoryBound(to: CChar.self)) == "trash" else { return }
            move()
        }
        adw_dialog_present(ptr(dialog), ptr(window))
    }

    /// Moves a confirmed item and reports how it went. Nil when another move is still running.
    @discardableResult
    func move(_ node: FileNodeRecord) async -> TrashOutcome? {
        guard let outcome = await model.moveToTrash(node) else {
            gtk_widget_error_bell(ptr(window))
            return nil
        }
        switch outcome {
        case .moved(let bytes):
            reportMoved(count: 1, bytes: bytes)
        case .alreadyGone:
            showToast(TrashReport.alreadyGone(1))
        case .failed(let reason):
            showAlert(heading: L("Couldn't Move “%@” to the Trash", node.name), body: reason)
        }
        return outcome
    }

    /// Moves confirmed items and reports them together: one toast for what moved, one alert for what didn't.
    @discardableResult
    func move(_ nodes: [FileNodeRecord]) async -> [TrashOutcome]? {
        guard let outcomes = await model.moveToTrash(nodes) else {
            gtk_widget_error_bell(ptr(window))
            return nil
        }
        let summary = TrashBatchSummary(outcomes)
        if summary.moved > 0 { reportMoved(count: summary.moved, bytes: summary.bytes) }
        if summary.gone > 0 { showToast(TrashReport.alreadyGone(summary.gone)) }
        if let reason = summary.firstFailure {
            showAlert(heading: summary.failed == 1
                ? L("Couldn't Move 1 Item to the Trash")
                : L("Couldn't Move %lld Items to the Trash", Int64(summary.failed)), body: reason)
        }
        return outcomes
    }

    /// No Undo: putting an item back is the file manager's job, and it knows where each one came from.
    private func reportMoved(count moved: Int, bytes: Int64) {
        let count = (movedToast?.count ?? 0) + moved
        let total = (movedToast?.bytes ?? 0) + bytes
        if let previous = movedToast?.toast.pointer {
            adw_toast_dismiss(ptr(previous))
        }
        guard let toast = showToast(TrashReport.moved(count, bytes: total), button: (L("Open Trash"), "win.open-trash")) else { return }
        movedToast = (toast, count, total)
        connect(toast.pointer, "dismissed") { [weak self, unowned toast] in
            if self?.movedToast?.toast === toast { self?.movedToast = nil }
        }
    }

    /// Plain text: names and paths may hold markup characters.
    @discardableResult
    private func showToast(_ text: String, button: (label: String, action: String)? = nil) -> GObjectRef? {
        guard let toast = adw_toast_new(text) else { return nil }
        adw_toast_set_use_markup(toast, gbool(false))
        if let button {
            adw_toast_set_button_label(toast, button.label)
            adw_toast_set_action_name(toast, button.action)
        }
        let kept = GObjectRef(retaining: raw(toast)!)
        // The overlay takes the constructor's reference.
        adw_toast_overlay_add_toast(ptr(toastOverlay), toast)
        return kept
    }

    /// Reasons run longer than a toast's single line.
    private func showAlert(heading: String, body: String) {
        let dialog = raw(adw_alert_dialog_new(heading, body))!
        adw_alert_dialog_add_response(ptr(dialog), "close", L("OK"))
        adw_alert_dialog_set_default_response(ptr(dialog), "close")
        adw_alert_dialog_set_close_response(ptr(dialog), "close")
        adw_dialog_present(ptr(dialog), ptr(window))
        // libadwaita 1.5 focuses the default response only when another response would take focus first, so a
        // lone OK starts on the scrollable message instead and Return does nothing. The buttons exist once the
        // dialog is presented, and it focuses this one as it opens.
        if let button = Widgets.firstDescendant(of: dialog, ofType: gtk_button_get_type()) {
            adw_dialog_set_focus(ptr(dialog), ptr(button))
        }
    }

    private func chooseFolder() {
        let dialog = gtk_file_dialog_new()
        gtk_file_dialog_set_title(dialog, L("Choose a Folder or Disk"))
        gtk_file_dialog_set_modal(dialog, gbool(true))
        let context = Unmanaged.passRetained(self).toOpaque()
        gtk_file_dialog_select_folder(dialog, ptr(window), nil, { source, result, data in
            let window = Unmanaged<MainWindow>.fromOpaque(data!).takeRetainedValue()
            guard let file = gtk_file_dialog_select_folder_finish(OpaquePointer(source), result, nil) else { return }
            defer { g_object_unref(raw(file)) }
            guard let path = takeString(g_file_get_path(file)) else { return }
            MainActor.assumeIsolated {
                window.model.open(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: .folder))
            }
        }, context)
        g_object_unref(raw(dialog))
    }
}

private extension VizView {
    var iconName: String {
        switch self {
        case .cushion: "neodisk-treemap-symbolic"
        case .flat: "neodisk-treemap-flat-symbolic"
        case .sunburst: "neodisk-sunburst-symbolic"
        }
    }
}
