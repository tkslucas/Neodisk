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
                        builtInLocationRow(target, now: now, bar: nil)
                    }
                }
            }

            if model.cloudScan?.canConnectAccounts == true || !model.cloudDriveAccounts.isEmpty {
                Section("Cloud Drives") {
                    ForEach(model.cloudDriveAccounts) { target in
                        // No Reveal-in-Finder context menu: cloudscan:// IDs
                        // are not filesystem paths, so these rows can't reuse
                        // builtInLocationRow.
                        SidebarTargetRow(
                            target: target,
                            subtitle: model.cloudScan?.accountSubtitle(forTargetID: target.id) ?? target.id,
                            lastScanned: model.cachedScanInfo[target.id]?.lastScanDate,
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
                        lastScanned: model.cachedScanInfo[target.id]?.lastScanDate,
                        now: now
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
                model.signOutCloudAccount(targetID: target.id)
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
    /// configured provider is a plain button; multiple become a menu.
    @ViewBuilder
    private var cloudConnectButton: some View {
        if let items = model.cloudScan?.connectMenuItems, !items.isEmpty {
            if items.count == 1 {
                let item = items[0]
                Button {
                    model.connectCloudAccount(providerID: item.id)
                } label: {
                    sidebarActionLabel(title: item.title, systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Connect a cloud account and keep it in the sidebar")
            } else {
                Menu {
                    ForEach(items, id: \.id) { item in
                        Button(LocalizedStringKey(item.title)) { model.connectCloudAccount(providerID: item.id) }
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
            lastScanned: model.cachedScanInfo[target.id]?.lastScanDate,
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

    // MARK: - Volume capacity bars

    /// Reloads whenever a sidecar lands or the palette changes. The
    /// sidecar generation — not the scan date — is the fresh-scan trigger:
    /// the sidecar is written asynchronously after the save that updates
    /// `cachedScanInfo`, so a date-keyed reload would run too early, find
    /// no sidecar, and leave the bar empty until the next scan.
    private var volumeBarsTaskID: String {
        let scans = model.volumeLocations.map { target in
            "\(target.id)|\(model.cachedScanInfo[target.id].map(\.lastScanDate.timeIntervalSince1970) ?? 0)"
        }
        return scans.joined(separator: ",")
            + "|\(model.kindStatsSidecarGeneration)"
            + "|\(model.preferences?.useColorblindPalette == true)"
    }

    private func loadVolumeBars() async {
        let palette = model.vizPalette
        var bars: [String: VolumeBarData] = [:]
        for target in model.volumeLocations {
            // Never scanned → the bar stays an empty track (no sidecar to
            // color it, and no misleading half-answer from volume stats).
            guard model.cachedScanInfo[target.id] != nil else { continue }
            guard let sidecar = await model.loadKindStatsSidecar(forTargetID: target.id) else {
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

// MARK: - Volume capacity bar

/// The macOS-storage-style bar under a volume row: one segment per file
/// kind category (same colors as the Kinds tab, palette-aware), a neutral
/// segment for used-but-unscanned capacity (hidden space / other users),
/// and the empty track standing for free space. `.empty` before any scan.
nonisolated struct VolumeBarData: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Identifiable {
        let id: String
        let rgb: SIMD3<Float>
        /// Fraction of the volume's total capacity.
        let fraction: Double

        var color: Color {
            Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
        }
    }

    let segments: [Segment]

    static let empty = VolumeBarData(segments: [])

    static func make(
        volumeURL: URL,
        sidecar: KindStatsSidecar,
        palette: VizPalette
    ) -> VolumeBarData {
        guard let total = SystemIntegration.volumeTotalCapacity(for: volumeURL),
              total > 0 else {
            return .empty
        }

        var segments: [Segment] = []
        var scannedBytes: Int64 = 0
        let categories = sidecar.stats(for: .categories)
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        for stat in categories {
            scannedBytes += stat.size
            segments.append(Segment(
                id: stat.kindID,
                rgb: palette.categoryRGB[stat.kindID] ?? FileKindCatalog.otherRGB,
                fraction: Double(stat.size) / Double(total)
            ))
        }

        // Used capacity the scan didn't account for (hidden space, other
        // users' homes): a neutral tail segment, like macOS "System Data".
        if let available = SystemIntegration.volumeAvailableCapacityForImportantUsage(for: volumeURL) {
            let unaccounted = total - available - scannedBytes
            if unaccounted > 0 {
                segments.append(Segment(
                    id: "unscanned",
                    rgb: FileKindCatalog.otherRGB,
                    fraction: Double(unaccounted) / Double(total)
                ))
            }
        }

        return VolumeBarData(segments: segments)
    }
}

private struct VolumeCapacityBar: View {
    let data: VolumeBarData

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(data.segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: geometry.size.width * segment.fraction)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.12))
        .clipShape(Capsule())
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
    /// Volume rows only: the capacity bar (empty track before any scan).
    var bar: VolumeBarData?

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
                if let bar {
                    VolumeCapacityBar(data: bar)
                        .padding(.top, 3)
                        .padding(.bottom, 1)
                        .padding(.trailing, 2)
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
        // Remote cloud-drive account (CloudScan): distinct from the local
        // iCloud/Dropbox sync folders below.
        if target.kind == .cloud {
            return "externaldrive.badge.icloud"
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
