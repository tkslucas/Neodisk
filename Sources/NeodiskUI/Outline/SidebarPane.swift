//
//  SidebarPane.swift
//  Neodisk
//
//  Smart Locations sidebar: volumes and common folders, one click to scan,
//  user-pinned folders with multi-select removal, and an Add Folder action.
//

import AppKit
import SwiftUI
import NeodiskKit

struct SidebarPane: View {
    let model: NeodiskViewModel

    @State private var selection: Set<String> = []
    @State private var capacityByPath: [String: String] = [:]

    /// Pinned folders, minus any that duplicate a smart location.
    private var visiblePinnedFolders: [ScanTarget] {
        let smartIDs = Set(model.smartLocations.map(\.id))
        return model.pinnedFolders.filter { !smartIDs.contains($0.id) }
    }

    var body: some View {
        // The rows show relative "Scanned … ago" strings, which silently go
        // stale in a long-lived window ("just now" forever); re-evaluate
        // them once a minute. The timeline date must flow into the rows —
        // with unchanged inputs SwiftUI skips their bodies and the schedule
        // alone refreshes nothing.
        TimelineView(.everyMinute) { context in
            sidebarList(now: context.date)
        }
    }

    private func sidebarList(now: Date) -> some View {
        List(selection: $selection) {
            Section("Smart Locations") {
                ForEach(model.smartLocations) { target in
                    SidebarTargetRow(
                        target: target,
                        subtitle: capacityByPath[target.id] ?? target.id,
                        lastScanned: model.cachedScanInfo[target.id]?.lastScanDate,
                        now: now
                    )
                    .tag(target.id)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            SystemIntegration.reveal(target.url)
                        }
                    }
                }
            }

            if !visiblePinnedFolders.isEmpty {
                Section("Folders") {
                    ForEach(visiblePinnedFolders) { target in
                        SidebarTargetRow(
                            target: target,
                            subtitle: target.id,
                            lastScanned: model.cachedScanInfo[target.id]?.lastScanDate,
                            now: now
                        )
                        .tag(target.id)
                        .contextMenu { removeMenu(clicked: target) }
                    }
                }
            }

            Section {
                Button {
                    model.chooseFolderAndScan()
                } label: {
                    HStack {
                        Spacer()
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Scan any folder or volume and keep it in the sidebar")
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            model.addDroppedFolders(urls)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("v\(AppVersion.string)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        }
        .onDeleteCommand {
            removeSelectedFolders()
        }
        .onChange(of: selection) { _, newSelection in
            // Multi-selection only makes sense for removable folders (the
            // point is bulk removal), so strip smart locations out of any
            // multi-select — this also covers ⌘A, which the list's table
            // handles itself before onCommand interceptors ever see it.
            if newSelection.count > 1 {
                let smartIDs = Set(model.smartLocations.map(\.id))
                let filtered = newSelection.subtracting(smartIDs)
                if filtered != newSelection {
                    selection = filtered
                    return
                }
            }

            // A plain click (no ⌘/⇧ multi-select in flight) activates a scan;
            // modifier clicks only adjust the selection.
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            guard newSelection.count == 1,
                  let targetID = newSelection.first,
                  !modifiers.contains(.command),
                  !modifiers.contains(.shift),
                  targetID != model.coordinator.selectedTarget?.id,
                  let target = allTargets.first(where: { $0.id == targetID }) else {
                return
            }
            model.startScan(target)
        }
        .onChange(of: model.coordinator.selectedTarget, initial: true) { _, target in
            // Keep the highlighted row in sync with what is being scanned
            // (drag & drop, welcome buttons, Add Folder…).
            if let target {
                if selection != [target.id] {
                    selection = [target.id]
                }
            } else if !selection.isEmpty {
                // A cleared scan must not leave a stale highlighted row.
                selection = []
            }
        }
        .task {
            capacityByPath = await Task.detached(priority: .utility) {
                SystemIntegration.targetCapacityDescriptions()
            }.value
        }
    }

    private var allTargets: [ScanTarget] {
        model.smartLocations + visiblePinnedFolders
    }

    private var selectedPinnedIDs: Set<String> {
        selection.intersection(visiblePinnedFolders.map(\.id))
    }

    @ViewBuilder
    private func removeMenu(clicked target: ScanTarget) -> some View {
        let ids = selectedPinnedIDs.contains(target.id) ? selectedPinnedIDs : [target.id]
        Button("Reveal in Finder") {
            SystemIntegration.reveal(target.url)
        }
        Divider()
        Button(ids.count > 1 ? "Remove \(ids.count) Folders from Sidebar" : "Remove from Sidebar") {
            model.removePinnedFolders(ids: ids)
            selection.subtract(ids)
        }
    }

    private func removeSelectedFolders() {
        let ids = selectedPinnedIDs
        guard !ids.isEmpty else { return }
        model.removePinnedFolders(ids: ids)
        selection.subtract(ids)
    }
}

private struct SidebarTargetRow: View {
    let target: ScanTarget
    let subtitle: String
    /// When a persisted snapshot exists for this location, its scan date
    /// gets its own line ("Scanned yesterday") — sharing the capacity line
    /// middle-truncated both.
    var lastScanned: Date?
    /// Reference date for the relative scan label, from the enclosing
    /// TimelineView.
    var now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundStyle(.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let lastScanned {
                    Text("Scanned \(DisplayFormatters.relativeDate(lastScanned, relativeTo: now))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var iconName: String {
        if target.kind == .volume {
            return "internaldrive.fill"
        }
        if CloudLocationDetector.isCloudPath(target.id) || target.displayName == "Dropbox" {
            return target.displayName.hasPrefix("iCloud") ? "icloud.fill" : "cloud.fill"
        }
        switch target.displayName {
        case "Home", NSUserName():
            return "house.fill"
        case "Desktop":
            return "menubar.dock.rectangle"
        case "Documents":
            return "doc.on.doc.fill"
        case "Downloads":
            return "arrow.down.circle.fill"
        case "Library":
            return "books.vertical.fill"
        case "Applications":
            return "square.grid.2x2.fill"
        default:
            return "folder.fill"
        }
    }
}
