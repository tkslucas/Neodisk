//
//  SidebarView.swift
//  NeodiskGTK
//
//  The locations sidebar: Home, the root filesystem, mounted volumes with a
//  capacity bar (split by file kind once scanned), and recently scanned
//  folders. Rows say how much is free and
//  when the location was last scanned; activating one opens it (instantly
//  from the snapshot cache when a scan is on file). The list follows mounts
//  and unmounts live through GIO's volume monitor.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class SidebarView {
    let widget: GPtr
    private let model: AppModel
    private let locationsList: GPtr
    private let recentsList: GPtr
    private let recentsHeading: GPtr
    private var locations: [Location] = []
    private var recents: [Location] = []
    private var volumeMonitor: GObjectRef?
    /// The bars on screen, by location, and the segments last loaded for
    /// each scanned volume (rows are rebuilt often; segments outlive them).
    private var capacityBars: [String: CapacityBar] = [:]
    private var segments: [String: [VolumeCapacitySegment]] = [:]
    private var segmentsTask: Task<Void, Never>?
    private var tokens: [ObservationToken] = []

    init(model: AppModel) {
        self.model = model

        let locationsHeading = Widgets.label(L("Locations"), classes: ["heading", "dim-label"])
        Widgets.setMargins(locationsHeading, top: 12, bottom: 6, start: 18, end: 12)
        locationsList = raw(gtk_list_box_new())!
        Widgets.addClasses(locationsList, ["navigation-sidebar"])

        recentsHeading = Widgets.label(L("Recent"), classes: ["heading", "dim-label"])
        Widgets.setMargins(recentsHeading, top: 12, bottom: 6, start: 18, end: 12)
        recentsList = raw(gtk_list_box_new())!
        Widgets.addClasses(recentsList, ["navigation-sidebar"])

        let openButton = raw(gtk_button_new())!
        let openContent = raw(adw_button_content_new())!
        adw_button_content_set_icon_name(ptr(openContent), "folder-open-symbolic")
        adw_button_content_set_label(ptr(openContent), L("Choose Folder…"))
        gtk_button_set_child(ptr(openButton), ptr(openContent))
        Widgets.addClasses(openButton, ["flat"])
        gtk_actionable_set_action_name(ptr(openButton), "win.open-folder")
        Widgets.setMargins(openButton, top: 6, bottom: 12, start: 6, end: 6)

        let column = Widgets.box(GTK_ORIENTATION_VERTICAL, [
            locationsHeading, locationsList, recentsHeading, recentsList, openButton,
        ])
        widget = Widgets.scrolled(column)
        attach(self, to: widget, key: "neodisk-sidebar")

        connectPointer(locationsList, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.locations.indices.contains(index) else { return }
            self.model.open(self.locations[index].target)
        }
        connectPointer(recentsList, "row-activated") { [unowned self] row in
            let index = Int(gtk_list_box_row_get_index(ptr(row)))
            guard self.recents.indices.contains(index) else { return }
            self.model.open(self.recents[index].target)
        }

        if let monitor = g_volume_monitor_get() {
            let reference = GObjectRef(adopting: raw(monitor)!)
            volumeMonitor = reference
            for signal in ["mount-added", "mount-removed", "mount-changed"] {
                connectPointer(reference.pointer, signal) { [unowned self] _ in
                    self.reloadLocations()
                }
            }
        }

        reloadLocations()
        tokens.append(track { [unowned self] in
            _ = self.model.cachedScans
            _ = self.model.phase
            _ = self.model.minuteTick
            self.reloadLocations()
        })
        tokens.append(track { [unowned self] in
            self.reloadRecents(self.model.preferences.recentFolders)
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

        Task { [weak self] in
            guard let self else { return }
            await self.model.refreshCachedScans(keeping: Set(self.locations.map(\.id)))
        }
    }

    // MARK: - Rows

    private func reloadLocations() {
        locations = Locations.current()
        capacityBars = [:]
        gtk_list_box_remove_all(ptr(locationsList))
        for location in locations {
            gtk_list_box_append(ptr(locationsList), ptr(makeRow(for: location)))
        }
        syncSelection(with: model.target?.id)
    }

    private func reloadRecents(_ folders: [String]) {
        let locationIDs = Set(locations.map(\.id))
        recents = folders
            .filter { !locationIDs.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .map(Locations.folder)
        gtk_list_box_remove_all(ptr(recentsList))
        for location in recents {
            gtk_list_box_append(ptr(recentsList), ptr(makeRow(for: location)))
        }
        Widgets.setVisible(recentsHeading, !recents.isEmpty)
        Widgets.setVisible(recentsList, !recents.isEmpty)
        syncSelection(with: model.target?.id)
    }

    private func makeRow(for location: Location) -> GPtr {
        let icon = Widgets.image(location.iconName)
        let title = Widgets.label(location.title, ellipsize: true)
        let subtitle = Widgets.label(subtitleText(for: location), classes: ["dim-label", "neodisk-caption"], ellipsize: true)
        let text = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 2, [title, subtitle])
        gtk_widget_set_hexpand(ptr(text), gbool(true))

        if let space = location.space, space.totalCapacity > 0 {
            let bar = CapacityBar(space: space)
            bar.segments = segments[location.id] ?? []
            capacityBars[location.id] = bar
            Widgets.setMargins(bar.widget, top: 4, bottom: 1, end: 2)
            Widgets.append(text, bar.widget)
        }

        let content = Widgets.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, classes: ["neodisk-sidebar-row"], [icon, text])
        let row = raw(gtk_list_box_row_new())!
        gtk_list_box_row_set_child(ptr(row), ptr(content))
        // On the name and details only: over the capacity bar, its own
        // bubble answers instead.
        for label in [icon, title, subtitle] {
            gtk_widget_set_tooltip_text(ptr(label), location.path)
        }
        return row
    }

    /// Colors each scanned volume's bar from its kind-stats sidecar. A
    /// volume never scanned keeps the plain used/total bar.
    private func reloadSegments() {
        let volumes = locations.filter { $0.space != nil && model.cachedScans[$0.id] != nil }
        let scannedBytes = volumes.map { model.cachedScans[$0.id]?.totalAllocatedSize ?? 0 }
        let palette = model.palette
        segmentsTask?.cancel()
        segmentsTask = Task { [weak self] in
            guard let self else { return }
            var loaded: [String: [VolumeCapacitySegment]] = [:]
            for (volume, scanned) in zip(volumes, scannedBytes) {
                guard let sidecar = await self.model.loadKindStatsSidecar(forTargetID: volume.id) else { continue }
                loaded[volume.id] = VolumeCapacitySegments.make(
                    space: volume.space,
                    sidecar: sidecar,
                    scannedBytes: scanned,
                    palette: palette
                )
            }
            guard !Task.isCancelled else { return }
            self.segments = loaded
            for (id, bar) in self.capacityBars {
                bar.segments = loaded[id] ?? []
            }
        }
    }

    private func subtitleText(for location: Location) -> String {
        var parts: [String] = []
        if let space = location.space, space.totalCapacity > 0 {
            parts.append(L(
                "%@ free of %@",
                NeodiskFormatters.size(space.availableCapacity),
                NeodiskFormatters.size(space.totalCapacity)
            ))
        } else if let subtitle = location.subtitle, location.kind == .folder {
            parts.append(subtitle)
        }
        if model.isScanning, model.target?.id == location.id {
            parts.append(L("Scanning…"))
        } else if let cached = model.cachedScans[location.id] {
            parts.append(L("Scanned %@", DisplayFormatters.relativeDate(cached.lastScanDate)))
        }
        return parts.joined(separator: " · ")
    }

    private func syncSelection(with targetID: String?) {
        let locationIndex = targetID.flatMap { id in locations.firstIndex { $0.id == id } }
        let recentIndex = targetID.flatMap { id in recents.firstIndex { $0.id == id } }
        if let locationIndex {
            gtk_list_box_select_row(ptr(locationsList), gtk_list_box_get_row_at_index(ptr(locationsList), Int32(locationIndex)))
        } else {
            gtk_list_box_unselect_all(ptr(locationsList))
        }
        if let recentIndex {
            gtk_list_box_select_row(ptr(recentsList), gtk_list_box_get_row_at_index(ptr(recentsList), Int32(recentIndex)))
        } else {
            gtk_list_box_unselect_all(ptr(recentsList))
        }
    }
}
