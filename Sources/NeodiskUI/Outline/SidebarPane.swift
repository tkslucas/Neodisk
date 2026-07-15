//
//  SidebarPane.swift
//  Neodisk
//
//  Locations sidebar: mounted volumes (each with a kind-colored capacity
//  bar), detected cloud storage folders, and one flat Folders section —
//  seeded with the common folders, extended by Add Folder, every row
//  removable. One click scans.
//

import AppKit
import SwiftUI
import NeodiskKit

struct SidebarPane: View {
    let model: NeodiskViewModel

    @State private var selection: Set<String> = []
    @State private var capacityByPath: [String: String] = [:]
    @State private var volumeBars: [String: VolumeBarData] = [:]
    /// The cloud account a sign-out confirmation is pending for.
    @State private var signOutTarget: ScanTarget?

    /// Sidebar folders, minus any that duplicate a built-in location.
    private var visibleFolders: [ScanTarget] {
        let builtInIDs = Set(model.builtInLocations.map(\.id))
        return model.sidebarFolders.filter { !builtInIDs.contains($0.id) }
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
            Section("Volumes") {
                ForEach(model.volumeLocations) { target in
                    builtInLocationRow(target, now: now, bar: volumeBars[target.id] ?? .empty)
                }
            }

            if !model.cloudLocations.isEmpty {
                Section("Local Cloud Files") {
                    ForEach(model.cloudLocations) { target in
                        builtInLocationRow(target, now: now, bar: cloudBar(for: target))
                    }
                }
            }

            if model.cloudAccounts.integration != nil || !model.cloudAccounts.accounts.isEmpty {
                Section("Cloud Drives") {
                    ForEach(model.cloudAccounts.accounts) { target in
                        // No Reveal-in-Finder context menu: cloudscan:// IDs
                        // are not filesystem paths, so these rows can't reuse
                        // builtInLocationRow.
                        SidebarTargetRow(
                            target: target,
                            subtitle: model.cloudAccounts.integration?.accountSubtitle(forTargetID: target.id) ?? target.id,
                            lastScanned: model.session.cachedScanInfo[target.id]?.lastScanDate,
                            now: now
                        )
                        .tag(target.id)
                        .contextMenu {
                            Button("Sign Out…") { signOutTarget = target }
                        }
                    }

                    cloudConnectButton
                }
            }

            Section("Folders") {
                ForEach(visibleFolders) { target in
                    SidebarTargetRow(
                        target: target,
                        subtitle: capacityByPath[target.id] ?? target.id,
                        lastScanned: model.session.cachedScanInfo[target.id]?.lastScanDate,
                        now: now,
                        bar: cloudBar(for: target)
                    )
                    .tag(target.id)
                    .contextMenu { removeMenu(clicked: target) }
                }

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
        .confirmationDialog(
            "Sign out of this cloud drive?",
            isPresented: Binding(
                get: { signOutTarget != nil },
                set: { if !$0 { signOutTarget = nil } }
            ),
            presenting: signOutTarget
        ) { target in
            Button("Sign Out", role: .destructive) {
                model.cloudAccounts.signOut(targetID: target.id)
                signOutTarget = nil
            }
            Button("Cancel", role: .cancel) { signOutTarget = nil }
        } message: { target in
            Text("Neodisk will disconnect \(target.displayName) and remove its cached scan. You can reconnect at any time.")
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
            // point is bulk removal), so strip built-in locations out of any
            // multi-select — this also covers ⌘A, which the list's table
            // handles itself before onCommand interceptors ever see it.
            if newSelection.count > 1 {
                let builtInIDs = Set(model.builtInLocations.map(\.id))
                let filtered = newSelection.subtracting(builtInIDs)
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
        .task(id: volumeBarsTaskID) {
            await loadVolumeBars()
        }
    }

    private var allTargets: [ScanTarget] {
        model.builtInLocations + visibleFolders
    }

    /// The Cloud Drives footer button, styled like "Add Folder…". A single
    /// configured provider is a plain button; multiple become a menu. When
    /// CloudScan is built in but no provider is configured (e.g. a release
    /// packaged before Google's verification clears), the button shows
    /// disabled as a "Coming soon" teaser instead of disappearing, per the
    /// persistent-controls rule in AGENTS.md.
    @ViewBuilder
    private var cloudConnectButton: some View {
        if let items = model.cloudAccounts.integration?.connectMenuItems, items.isEmpty {
            sidebarActionLabel(
                title: "Google Drive: coming soon",
                systemImage: "externaldrive.badge.plus"
            )
            .foregroundStyle(.secondary)
            .help("Cloud drive scanning is coming in an upcoming update")
        }
        if let items = model.cloudAccounts.integration?.connectMenuItems, !items.isEmpty {
            if items.count == 1 {
                let item = items[0]
                Button {
                    model.cloudAccounts.connect(providerID: item.id)
                } label: {
                    sidebarActionLabel(title: item.title, systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Connect a cloud account and keep it in the sidebar")
            } else {
                Menu {
                    ForEach(items, id: \.id) { item in
                        Button(LocalizedStringKey(item.title)) { model.cloudAccounts.connect(providerID: item.id) }
                    }
                } label: {
                    sidebarActionLabel(title: "Connect Cloud Drive…", systemImage: "externaldrive.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Connect a cloud account and keep it in the sidebar")
            }
        }
    }

    /// Shared styling for the sidebar's full-width action buttons (Add
    /// Folder…, Connect …). The title routes through LocalizedStringKey —
    /// a String-typed value passed to Label is never localized.
    private func sidebarActionLabel(title: String, systemImage: String) -> some View {
        HStack {
            Spacer()
            Label(LocalizedStringKey(title), systemImage: systemImage)
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

    /// One row of the Volumes or Local Cloud Files section: not removable,
    /// so the context menu only offers Reveal in Finder. Volume rows carry
    /// the capacity bar.
    private func builtInLocationRow(
        _ target: ScanTarget,
        now: Date,
        bar: VolumeBarData?
    ) -> some View {
        SidebarTargetRow(
            target: target,
            subtitle: capacityByPath[target.id] ?? target.id,
            lastScanned: model.session.cachedScanInfo[target.id]?.lastScanDate,
            now: now,
            bar: bar
        )
        .tag(target.id)
        .contextMenu {
            Button("Reveal in Finder") {
                SystemIntegration.reveal(target.url)
            }
        }
    }

    private var selectedFolderIDs: Set<String> {
        selection.intersection(visibleFolders.map(\.id))
    }

    @ViewBuilder
    private func removeMenu(clicked target: ScanTarget) -> some View {
        let ids = selectedFolderIDs.contains(target.id) ? selectedFolderIDs : [target.id]
        Button("Reveal in Finder") {
            SystemIntegration.reveal(target.url)
        }
        Divider()
        Button(ids.count > 1 ? "Remove \(ids.count) Folders from Sidebar" : "Remove from Sidebar") {
            model.removeSidebarFolders(ids: ids)
            selection.subtract(ids)
        }
    }

    private func removeSelectedFolders() {
        let ids = selectedFolderIDs
        guard !ids.isEmpty else { return }
        model.removeSidebarFolders(ids: ids)
        selection.subtract(ids)
    }

    /// The on-this-Mac / cloud-only bar under scanned cloud locations and
    /// folders — straight from the cache index, no snapshot decode. Volume
    /// rows keep their kind-colored capacity bar instead.
    private func cloudBar(for target: ScanTarget) -> VolumeBarData? {
        guard let info = model.session.cachedScanInfo[target.id] else { return nil }
        return VolumeBarData.cloudProportions(
            onThisMac: info.totalAllocatedSize,
            cloudOnly: info.cloudOnlyLogicalSize
        )
    }

    // MARK: - Volume capacity bars

    /// Reloads whenever a sidecar lands or the palette changes. The
    /// sidecar generation — not the scan date — is the fresh-scan trigger:
    /// the sidecar is written asynchronously after the save that updates
    /// `cachedScanInfo`, so a date-keyed reload would run too early, find
    /// no sidecar, and leave the bar empty until the next scan.
    private var volumeBarsTaskID: String {
        let scans = model.volumeLocations.map { target in
            "\(target.id)|\(model.session.cachedScanInfo[target.id].map(\.lastScanDate.timeIntervalSince1970) ?? 0)"
        }
        return scans.joined(separator: ",")
            + "|\(model.session.kindStatsSidecarGeneration)"
            + "|\(model.preferences?.useColorblindPalette == true)"
    }

    private func loadVolumeBars() async {
        let palette = model.vizPalette
        var bars: [String: VolumeBarData] = [:]
        for target in model.volumeLocations {
            // Never scanned → the bar stays an empty track (no sidecar to
            // color it, and no misleading half-answer from volume stats).
            guard model.session.cachedScanInfo[target.id] != nil else { continue }
            guard let sidecar = await model.session.loadKindStatsSidecar(forTargetID: target.id) else {
                continue
            }
            let url = target.url
            bars[target.id] = await Task.detached(priority: .utility) {
                VolumeBarData.make(volumeURL: url, sidecar: sidecar, palette: palette)
            }.value
        }
        volumeBars = bars
    }
}
