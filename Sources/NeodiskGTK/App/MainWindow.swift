//
//  MainWindow.swift
//  NeodiskGTK
//
//  The window, in libadwaita's idiom: an overlay split view with the
//  locations sidebar on the left and the workspace on the right. The
//  workspace mirrors the Mac layout — visualization over the file outline,
//  statistics on the right, status bar along the bottom — and so does its
//  header bar: the scan title on the left, the three-way view switcher in
//  the middle, scan controls and the statistics toggle on the right.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class MainWindow {
    let window: GPtr
    let model: AppModel

    private let splitView: GPtr
    private let titleLabel: GPtr
    private let subtitleLabel: GPtr
    private let contentStack: GPtr
    private let vizStack: GPtr
    private let workspacePaned: GPtr
    private let vizPaned: GPtr
    private let scanButton: GPtr
    private let stopButton: GPtr
    private let cushionToggle: GPtr
    private let flatToggle: GPtr
    private let sunburstToggle: GPtr

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
    private var tokens: [ObservationToken] = []

    init(application: GPtr, model: AppModel) {
        self.model = model
        let preferences = model.preferences

        window = raw(adw_application_window_new(ptr(application)))!
        gtk_window_set_default_size(ptr(window), Int32(preferences.windowWidth), Int32(preferences.windowHeight))
        // Breakpoints need a floor to collapse the layout against.
        gtk_widget_set_size_request(ptr(window), 640, 480)
        gtk_window_set_title(ptr(window), "Neodisk")

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
        let sidebarTitle = raw(adw_window_title_new("Neodisk", nil))!
        adw_header_bar_set_title_widget(ptr(sidebarHeader), ptr(sidebarTitle))
        let menuButton = raw(gtk_menu_button_new())!
        gtk_menu_button_set_icon_name(ptr(menuButton), "open-menu-symbolic")
        gtk_widget_set_tooltip_text(ptr(menuButton), L("Main Menu"))
        let primaryMenu = Widgets.menu([
            [(L("Choose Folder…"), "win.open-folder")],
            [(L("Preferences"), "app.preferences"), (L("Keyboard Shortcuts"), "win.show-help-overlay"), (L("About Neodisk"), "app.about")],
            [(L("Quit"), "app.quit")],
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
        titleLabel = Widgets.label("Neodisk", classes: ["heading"])
        gtk_label_set_ellipsize(ptr(titleLabel), PANGO_ELLIPSIZE_END)
        subtitleLabel = Widgets.label("", classes: ["dim-label", "neodisk-caption", "neodisk-numeric"])
        gtk_label_set_ellipsize(ptr(subtitleLabel), PANGO_ELLIPSIZE_END)
        let titleBox = Widgets.box(GTK_ORIENTATION_VERTICAL, [titleLabel, subtitleLabel])
        gtk_widget_set_valign(ptr(titleBox), GTK_ALIGN_CENTER)
        Widgets.setMargins(titleBox, start: 6)
        adw_header_bar_pack_start(ptr(header), ptr(titleBox))

        cushionToggle = Self.viewToggle("neodisk-treemap-symbolic", tooltip: L("Cushion Treemap"))
        flatToggle = Self.viewToggle("neodisk-treemap-flat-symbolic", tooltip: L("Flat Treemap"))
        sunburstToggle = Self.viewToggle("neodisk-sunburst-symbolic", tooltip: L("Sunburst"))
        gtk_toggle_button_set_group(ptr(flatToggle), ptr(cushionToggle))
        gtk_toggle_button_set_group(ptr(sunburstToggle), ptr(cushionToggle))
        let vizSwitcher = Widgets.box(GTK_ORIENTATION_HORIZONTAL, classes: ["linked"], [cushionToggle, flatToggle, sunburstToggle])
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

        workspacePaned = raw(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL))!
        gtk_paned_set_start_child(ptr(workspacePaned), ptr(vizPaned))
        gtk_paned_set_end_child(ptr(workspacePaned), ptr(statistics.widget))
        gtk_paned_set_resize_end_child(ptr(workspacePaned), gbool(false))
        gtk_paned_set_shrink_end_child(ptr(workspacePaned), gbool(false))
        gtk_paned_set_position(ptr(workspacePaned), Int32(max(480, preferences.windowWidth - 280 - 360)))

        let emptyState = raw(adw_status_page_new())!
        adw_status_page_set_icon_name(ptr(emptyState), "drive-harddisk-symbolic")
        adw_status_page_set_title(ptr(emptyState), L("Choose a Location to Scan"))
        adw_status_page_set_description(
            ptr(emptyState),
            L("Pick a disk or folder in the sidebar to see what takes up space. Neodisk only reads your files; it never changes or deletes them.")
        )
        let openButton = raw(gtk_button_new_with_label(L("Choose Folder…")))!
        Widgets.addClasses(openButton, ["pill", "suggested-action"])
        gtk_widget_set_halign(ptr(openButton), GTK_ALIGN_CENTER)
        gtk_actionable_set_action_name(ptr(openButton), "win.open-folder")
        adw_status_page_set_child(ptr(emptyState), ptr(openButton))

        contentStack = raw(gtk_stack_new())!
        gtk_stack_add_named(ptr(contentStack), ptr(emptyState), "empty")
        gtk_stack_add_named(ptr(contentStack), ptr(workspacePaned), "workspace")

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
        adw_application_window_set_content(ptr(window), ptr(splitView))

        // Collapse the sidebar into an overlay on narrow windows.
        if let condition = adw_breakpoint_condition_parse("max-width: 760sp") {
            let breakpoint = adw_breakpoint_new(condition)
            var value = GValue()
            g_value_init(&value, neodisk_boolean_type())
            g_value_set_boolean(&value, gbool(true))
            adw_breakpoint_add_setter(breakpoint, ptr(splitView), "collapsed", &value)
            g_value_unset(&value)
            adw_application_window_add_breakpoint(ptr(window), breakpoint)
        }
        // Narrower still, the statistics pane and the secondary outline
        // columns give way to the map and file names. The Statistics toggle
        // still shows the pane on demand.
        if let condition = adw_breakpoint_condition_parse("max-width: 900sp") {
            let breakpoint = adw_breakpoint_new(condition)
            var value = GValue()
            g_value_init(&value, neodisk_boolean_type())
            g_value_set_boolean(&value, gbool(false))
            for target in [statistics.widget] + outline.secondaryColumns {
                adw_breakpoint_add_setter(breakpoint, ptr(target), "visible", &value)
            }
            g_value_unset(&value)
            adw_application_window_add_breakpoint(ptr(window), breakpoint)
        }

        attach(self, to: window, key: "neodisk-main-window")
        installActions()
        bindModel(statisticsToggle: statisticsToggle)

        connect(cushionToggle, "toggled") { [unowned self] in
            if gtk_toggle_button_get_active(ptr(self.cushionToggle)) != 0 { self.showView(.cushion) }
        }
        connect(flatToggle, "toggled") { [unowned self] in
            if gtk_toggle_button_get_active(ptr(self.flatToggle)) != 0 { self.showView(.flat) }
        }
        connect(sunburstToggle, "toggled") { [unowned self] in
            if gtk_toggle_button_get_active(ptr(self.sunburstToggle)) != 0 { self.showView(.sunburst) }
        }
        connect(statisticsToggle, "toggled") { [unowned self] in
            self.model.preferences.showsStatistics = gtk_toggle_button_get_active(ptr(statisticsToggle)) != 0
        }
        connectNotify(window, "default-width") { [unowned self] in self.rememberSize() }
        connectNotify(window, "default-height") { [unowned self] in self.rememberSize() }
    }

    private static func viewToggle(_ iconName: String, tooltip: String) -> GPtr {
        let toggle = raw(gtk_toggle_button_new())!
        gtk_button_set_icon_name(ptr(toggle), iconName)
        gtk_widget_set_tooltip_text(ptr(toggle), tooltip)
        return toggle
    }

    /// The three center views, flattened for the switcher as on the Mac.
    /// Picking a treemap writes both preferences; Sunburst leaves the
    /// treemap style alone, so switching back restores it.
    private enum ViewChoice {
        case cushion, flat, sunburst
    }

    private func showView(_ choice: ViewChoice) {
        let preferences = model.preferences
        switch choice {
        case .cushion:
            preferences.vizMode = .treemap
            preferences.treemapStyle = .cushion
        case .flat:
            preferences.vizMode = .treemap
            preferences.treemapStyle = .flat
        case .sunburst:
            preferences.vizMode = .sunburst
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

    private func bindModel(statisticsToggle: GPtr) {
        tokens.append(track { [unowned self] in
            _ = self.model.minuteTick
            let hasContent = self.model.target != nil
            gtk_stack_set_visible_child_name(ptr(self.contentStack), hasContent ? "workspace" : "empty")

            let title = self.model.target.map(self.displayName) ?? "Neodisk"
            gtk_label_set_text(ptr(self.titleLabel), title)
            let subtitle = self.subtitle()
            gtk_label_set_text(ptr(self.subtitleLabel), subtitle ?? "")
            Widgets.setVisible(self.subtitleLabel, subtitle != nil)
            gtk_window_set_title(ptr(self.window), self.model.target == nil ? "Neodisk" : "\(title) — Neodisk")

            let scanning = self.model.isScanning || self.model.phase == .restoring
            // Persistent controls that disable when unusable, never vanish
            // (a product rule shared with the Mac).
            setActionEnabled(self.actions["rescan"], self.model.target != nil && !scanning)
            setActionEnabled(self.actions["stop"], scanning)
            Widgets.setVisible(self.stopButton, scanning)
            Widgets.setVisible(self.scanButton, !scanning)
            setActionEnabled(self.actions["focus-out"], self.model.canFocusOut)
            setActionEnabled(self.actions["search"], self.model.store != nil)
            let hasSelection = self.model.selectedNode != nil
            for name in ["open-item", "show-in-files", "copy-path"] {
                setActionEnabled(self.actions[name], hasSelection)
            }
        })
        tokens.append(track { [unowned self] in
            let mode = self.model.preferences.vizMode
            let style = self.model.preferences.treemapStyle
            gtk_stack_set_visible_child_name(ptr(self.vizStack), mode == .sunburst ? "sunburst" : "treemap")
            let toggle = mode == .sunburst ? self.sunburstToggle : style == .flat ? self.flatToggle : self.cushionToggle
            gtk_toggle_button_set_active(ptr(toggle), gbool(true))
        })
        tokens.append(track { [unowned self] in
            let shows = self.model.preferences.showsStatistics
            Widgets.setVisible(self.statistics.widget, shows)
            gtk_toggle_button_set_active(ptr(statisticsToggle), gbool(shows))
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
        actions["toggle-sidebar"] = addAction(to: window, "toggle-sidebar") { [unowned self] _ in
            let shown = adw_overlay_split_view_get_show_sidebar(ptr(self.splitView)) != 0
            adw_overlay_split_view_set_show_sidebar(ptr(self.splitView), gbool(!shown))
        }
        actions["show-cushion"] = addAction(to: window, "show-cushion") { [unowned self] _ in
            self.showView(.cushion)
        }
        actions["show-flat"] = addAction(to: window, "show-flat") { [unowned self] _ in
            self.showView(.flat)
        }
        actions["show-sunburst"] = addAction(to: window, "show-sunburst") { [unowned self] _ in
            self.showView(.sunburst)
        }
        actions["open-item"] = addAction(to: window, "open-item") { [unowned self] _ in
            guard let path = self.model.selectedNode?.path else { return }
            FileActions.open(path, from: self.window)
        }
        actions["show-in-files"] = addAction(to: window, "show-in-files") { [unowned self] _ in
            guard let path = self.model.selectedNode?.path else { return }
            FileActions.showInFileManager(path, from: self.window)
        }
        actions["copy-path"] = addAction(to: window, "copy-path") { [unowned self] _ in
            guard let path = self.model.selectedNode?.path else { return }
            FileActions.copyPath(path, from: self.window)
        }
        actions["scan-location"] = addAction(to: window, "scan-location", stringParameter: true) { [unowned self] path in
            guard let path else { return }
            self.model.open(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)))
        }
        addAction(to: window, "show-help-overlay") { [unowned self] _ in
            ShortcutsWindow.present(from: self.window)
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
