// Volumes, then Folders (home and the folders scanned lately), each collapsing from its header; right-clicking a
// header picks the sections shown. Scanned locations open instantly from the snapshot cache; mounts follow GIO live.

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class SidebarView {
    /// No cloud folders here, and moving to the Trash goes without a Cleanup list.
    static let sections: [SidebarSection] = [.volumes, .folders]

    let widget: GPtr
    /// "sidebar.show-<section>" checkboxes, for the headers' menu and the primary menu's Sidebar Sections.
    let actions: GObjectRef
    let sectionsMenu: GObjectRef
    private let model: AppModel
    private var expanders: [SidebarSection: GPtr] = [:]
    private var lists: [SidebarSection: GPtr] = [:]
    private var showActions: [SidebarSection: GPtr] = [:]
    private let column: GPtr
    private var sectionsPopover: GPtr?
    private var rows: [SidebarSection: [Location]] = [:]
    private var volumeMonitor: GObjectRef?
    /// Segments are kept apart from the bars because rows are rebuilt often and segments outlive them.
    private var capacityBars: [String: CapacityBar] = [:]
    private var segments: [String: [VolumeCapacitySegment]] = [:]
    private var segmentsTask: Task<Void, Never>?
    private var tokens: [ObservationToken] = []

    private var locations: [Location] { Self.sections.flatMap { rows[$0] ?? [] } }

    init(model: AppModel) {
        self.model = model
        actions = GObjectRef(adopting: raw(g_simple_action_group_new())!)
        sectionsMenu = Widgets.menu([Self.sections.map { (L($0.titleKey), "sidebar.show-\($0.rawValue)") }])

        let openButton = raw(gtk_button_new())!
        let openContent = raw(adw_button_content_new())!
        adw_button_content_set_icon_name(ptr(openContent), "folder-open-symbolic")
        adw_button_content_set_label(ptr(openContent), L("Choose Folder…"))
        gtk_button_set_child(ptr(openButton), ptr(openContent))
        Widgets.addClasses(openButton, ["flat"])
        gtk_actionable_set_action_name(ptr(openButton), "win.open-folder")
        Widgets.setMargins(openButton, top: 6, bottom: 12, start: 6, end: 6)

        column = Widgets.box(GTK_ORIENTATION_VERTICAL, [])
        widget = Widgets.scrolled(column)
        attach(self, to: widget, key: "neodisk-sidebar")
        for section in Self.sections {
            Widgets.append(column, makeSection(section))
        }
        Widgets.append(column, openButton)

        if let monitor = g_volume_monitor_get() {
            let reference = GObjectRef(adopting: raw(monitor)!)
            volumeMonitor = reference
            for signal in ["mount-added", "mount-removed", "mount-changed"] {
                connectPointer(reference.pointer, signal) { [unowned self] _ in
                    self.reload()
                }
            }
        }

        tokens.append(track { [unowned self] in
            _ = self.model.cachedScans
            _ = self.model.phase
            _ = self.model.minuteTick
            _ = self.model.preferences.recentFolders
            self.reload()
        })
        tokens.append(track { [unowned self] in
            self.syncSelection(with: self.model.target?.id)
        })
        tokens.append(track { [unowned self] in
            _ = self.model.cachedScans
            _ = self.model.kindStatsSidecarGeneration
            _ = self.model.preferences.paletteID
            self.reloadSegments()
        })
        tokens.append(track { [unowned self] in
            let state = self.model.preferences.sidebarSections
            for section in Self.sections {
                let shown = state.isShown(section, cleanupEnabled: false)
                Widgets.setVisible(self.expanders[section], shown)
                setActionState(self.showActions[section], shown)
                if (gtk_expander_get_expanded(ptr(self.expanders[section])) != 0) != state.isExpanded(section) {
                    gtk_expander_set_expanded(ptr(self.expanders[section]), gbool(state.isExpanded(section)))
                }
            }
        })

        Task { [weak self] in
            guard let self else { return }
            await self.model.refreshCachedScans(keeping: Set(self.locations.map(\.id)))
        }
    }

    // MARK: - Sections

    /// A header that expands and collapses its rows, GTK's own expander, and offers the sections menu.
    private func makeSection(_ section: SidebarSection) -> GPtr {
        let header = Widgets.label(L(section.titleKey), classes: ["heading", "dim-label"])
        gtk_widget_set_hexpand(ptr(header), gbool(true))
        let list = raw(gtk_list_box_new())!
        Widgets.addClasses(list, ["navigation-sidebar"])
        let expander = raw(gtk_expander_new(nil))!
        gtk_expander_set_label_widget(ptr(expander), ptr(header))
        gtk_expander_set_child(ptr(expander), ptr(list))
        gtk_expander_set_expanded(ptr(expander), gbool(true))
        Widgets.addClasses(expander, ["neodisk-sidebar-section"])
        expanders[section] = expander
        lists[section] = list

        connectNotify(expander, "expanded") { [unowned self] in
            self.model.preferences.sidebarSections.setExpanded(section, gtk_expander_get_expanded(ptr(expander)) != 0)
        }
        showActions[section] = addToggleAction(to: actions.pointer, "show-\(section.rawValue)") { [unowned self] shown in
            self.model.preferences.sidebarSections.setShown(section, shown)
        }
        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 3)
        connectPress(click, "pressed") { [unowned self] _, x, y in
            self.showSectionsMenu(from: section, at: CGPoint(x: x, y: y))
        }
        gtk_widget_add_controller(ptr(header), ptr(click))
        connectPointer(list, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard let rows = self.rows[section], rows.indices.contains(index) else { return }
            self.model.open(rows[index].target)
        }
        return expander
    }

    /// `point` is in the header's coordinates. The menu hangs off the column, which unparents it when it goes.
    func showSectionsMenu(from section: SidebarSection, at point: CGPoint) {
        var source = graphene_point_t(x: Float(point.x), y: Float(point.y))
        var local = graphene_point_t()
        guard let header = gtk_expander_get_label_widget(ptr(expanders[section])),
              gtk_widget_compute_point(header, ptr(column), &source, &local) != 0 else { return }
        Widgets.popupMenu(&sectionsPopover, model: sectionsMenu, on: column, at: CGPoint(x: Double(local.x), y: Double(local.y)))
    }

    // MARK: - Rows

    private func reload() {
        let volumes = Locations.volumes()
        let home = Locations.home()
        let fixedIDs = Set(volumes.map(\.id)).union([home.id])
        let recents = model.preferences.recentFolders
            .filter { !fixedIDs.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .map(Locations.folder)
        let previousIDs = locations.map(\.id)
        rows = [.volumes: volumes, .folders: [home] + recents]
        capacityBars = [:]
        for section in Self.sections {
            guard let list = lists[section] else { continue }
            Widgets.removeAllRows(of: list)
            for location in rows[section] ?? [] {
                gtk_list_box_append(ptr(list), ptr(makeRow(for: location)))
            }
        }
        if locations.map(\.id) != previousIDs { reloadSegments() }
        syncSelection(with: model.target?.id)
    }

    /// The name with its size trailing, a volume's usage, when it was scanned, then the bar; the path is the tooltip.
    private func makeRow(for location: Location) -> GPtr {
        let space = location.space.flatMap { $0.totalCapacity > 0 ? $0 : nil }
        let cached = model.cachedScans[location.id]
        let icon = Widgets.image(location.iconName)
        let name = Widgets.label(location.title, ellipsize: true)
        gtk_widget_set_hexpand(ptr(name), gbool(true))
        var labels = [name]
        if let size = SidebarRowText.size(space: space, scannedBytes: cached?.totalAllocatedSize) {
            labels.append(Widgets.label(size, classes: ["dim-label", "neodisk-caption", "neodisk-numeric"]))
        }
        for label in labels {
            gtk_widget_set_valign(ptr(label), GTK_ALIGN_BASELINE_FILL)
        }
        let text = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 2, [
            Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, labels),
        ])
        gtk_widget_set_hexpand(ptr(text), gbool(true))
        if let usage = SidebarRowText.usage(space: space) {
            let label = Widgets.label(usage, classes: ["dim-label", "neodisk-caption", "neodisk-numeric"], ellipsize: true)
            labels.append(label)
            Widgets.append(text, label)
        }
        let scanning = model.isScanning && model.target?.id == location.id
        if let detail = scanning ? L("Scanning…") : SidebarRowText.scanned(cached?.lastScanDate) {
            let label = Widgets.label(detail, classes: ["dim-label", "neodisk-caption"], ellipsize: true)
            labels.append(label)
            Widgets.append(text, label)
        }

        if space != nil || location.space == nil {
            let bar = CapacityBar(space: space)
            bar.segments = segments[location.id] ?? []
            capacityBars[location.id] = bar
            Widgets.setMargins(bar.widget, top: 4, bottom: 1, end: 2)
            Widgets.append(text, bar.widget)
        }

        let content = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, classes: ["neodisk-sidebar-row"], [icon, text])
        let row = raw(gtk_list_box_row_new())!
        gtk_list_box_row_set_child(ptr(row), ptr(content))
        // Not over the capacity bar: its own bubble answers there.
        for widget in [icon] + labels {
            gtk_widget_set_tooltip_text(ptr(widget), location.path)
        }
        return row
    }

    /// An unscanned volume keeps the plain used/total bar; an unscanned folder shows none.
    private func reloadSegments() {
        let scanned = locations.filter { model.cachedScans[$0.id] != nil }
        let scannedBytes = scanned.map { model.cachedScans[$0.id]?.totalAllocatedSize ?? 0 }
        let palette = model.palette
        segmentsTask?.cancel()
        segmentsTask = Task { [weak self] in
            guard let self else { return }
            var loaded: [String: [VolumeCapacitySegment]] = [:]
            for (location, scannedBytes) in zip(scanned, scannedBytes) {
                guard let sidecar = await self.model.loadKindStatsSidecar(forTargetID: location.id) else { continue }
                loaded[location.id] = if let space = location.space {
                    VolumeCapacitySegments.make(
                        space: space,
                        sidecar: sidecar,
                        scannedBytes: scannedBytes,
                        palette: palette
                    )
                } else {
                    VolumeCapacitySegments.composition(sidecar: sidecar, scannedBytes: scannedBytes, palette: palette)
                }
            }
            guard !Task.isCancelled else { return }
            self.segments = loaded
            for (id, bar) in self.capacityBars {
                bar.segments = loaded[id] ?? []
            }
        }
    }

    private func syncSelection(with targetID: String?) {
        for section in Self.sections {
            guard let list = lists[section] else { continue }
            if let index = targetID.flatMap({ id in rows[section]?.firstIndex { $0.id == id } }) {
                gtk_list_box_select_row(ptr(list), gtk_list_box_get_row_at_index(ptr(list), Int32(index)))
            } else {
                gtk_list_box_unselect_all(ptr(list))
            }
        }
    }
}
