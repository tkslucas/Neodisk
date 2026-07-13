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

            if model.cloudScan != nil || !model.cloudDriveAccounts.isEmpty {
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
    /// configured provider is a plain button; multiple become a menu. When
    /// CloudScan is built in but no provider is configured (e.g. a release
    /// packaged before Google's verification clears), the button shows
    /// disabled as a "Coming soon" teaser instead of disappearing, per the
    /// persistent-controls rule in AGENTS.md.
    @ViewBuilder
    private var cloudConnectButton: some View {
        if let items = model.cloudScan?.connectMenuItems, items.isEmpty {
            sidebarActionLabel(
                title: "Google Drive: coming soon",
                systemImage: "externaldrive.badge.plus"
            )
            .foregroundStyle(.secondary)
            .help("Cloud drive scanning is coming in an upcoming update")
        }
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

    /// The on-this-Mac / cloud-only bar under scanned cloud locations and
    /// folders — straight from the cache index, no snapshot decode. Volume
    /// rows keep their kind-colored capacity bar instead.
    private func cloudBar(for target: ScanTarget) -> VolumeBarData? {
        guard let info = model.cachedScanInfo[target.id] else { return nil }
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
        /// Localization key for the hover tooltip: a kind category display
        /// name, "Hidden Space" for the unscanned tail, or the cloud bar's
        /// "On this Mac" / "Cloud-only".
        let label: String
        let size: Int64
        let rgb: SIMD3<Float>
        /// Fraction of the volume's total capacity.
        let fraction: Double
        /// Overrides the rgb-derived fill — the cloud bar uses the dynamic
        /// accent color, which has no fixed rgb.
        var explicitColor: Color?
        /// Cloud-only segments wear the shared dataless hatch.
        var isHatched = false

        var color: Color {
            explicitColor ?? Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
        }
    }

    let segments: [Segment]
    /// Free capacity (important-usage) for the empty track's tooltip; nil
    /// hides that tooltip.
    let availableSize: Int64?

    static let empty = VolumeBarData(segments: [], availableSize: nil)

    /// The two-segment on-this-Mac / cloud-only proportion bar for scanned
    /// cloud locations — the sidebar-sized sibling of CloudSummaryStrip's
    /// bar, sharing its colors and the dataless hatch. Nil without any
    /// cloud-only bytes (nothing worth a bar).
    static func cloudProportions(onThisMac: Int64, cloudOnly: Int64) -> VolumeBarData? {
        guard cloudOnly > 0 else { return nil }
        let total = Double(onThisMac) + Double(cloudOnly)
        return VolumeBarData(
            segments: [
                Segment(
                    id: "on-this-mac",
                    label: "On this Mac",
                    size: onThisMac,
                    rgb: .zero,
                    fraction: Double(onThisMac) / total,
                    explicitColor: .accentColor
                ),
                Segment(
                    id: "cloud-only",
                    label: "Cloud-only",
                    size: cloudOnly,
                    rgb: .zero,
                    fraction: Double(cloudOnly) / total,
                    explicitColor: .accentColor.opacity(0.3),
                    isHatched: true
                ),
            ],
            availableSize: nil
        )
    }

    static func make(
        volumeURL: URL,
        sidecar: KindStatsSidecar,
        palette: VizPalette
    ) -> VolumeBarData {
        guard let total = SystemIntegration.volumeTotalCapacity(for: volumeURL),
              total > 0 else {
            return .empty
        }
        let available = SystemIntegration.volumeAvailableCapacityForImportantUsage(for: volumeURL)

        var segments: [Segment] = []
        var scannedBytes: Int64 = 0
        let categories = sidecar.stats(for: .categories)
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        for stat in categories {
            scannedBytes += stat.size
            segments.append(Segment(
                id: stat.kindID,
                label: FileKindClassifier.kind(forID: stat.kindID, mode: .categories).displayName,
                size: stat.size,
                rgb: palette.categoryRGB[stat.kindID] ?? FileKindCatalog.otherRGB,
                fraction: Double(stat.size) / Double(total)
            ))
        }

        // Used capacity the scan didn't account for (hidden space, other
        // users' homes): a neutral tail segment, like macOS "System Data".
        if let available {
            let unaccounted = total - available - scannedBytes
            if unaccounted > 0 {
                segments.append(Segment(
                    id: "unscanned",
                    label: "Hidden Space",
                    size: unaccounted,
                    rgb: FileKindCatalog.otherRGB,
                    fraction: Double(unaccounted) / Double(total)
                ))
            }
        }

        return VolumeBarData(segments: segments, availableSize: available)
    }
}

private struct VolumeCapacityBar: View {
    /// Sentinel hover ID for the empty (free-space) track after the
    /// segments.
    private static let freeTrackID = "free-track"
    /// Gap between the tooltip's tail tip and the top of the bar.
    private static let tooltipGap: CGFloat = 6

    let data: VolumeBarData

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The segment (or free track) the pointer is over; drives the bubble's
    /// expanded/contracted state.
    @State private var hoveredSegmentID: String?
    /// The segment the bubble describes. Outlives `hoveredSegmentID` so the
    /// contract animation keeps its content and place instead of vanishing.
    @State private var shownSegmentID: String?
    /// Measured bubble size; the tooltip stays invisible until the first
    /// measurement lands so it never flashes at an unclamped position.
    @State private var tooltipSize: CGSize = .zero
    /// Pending delayed unhover; sliding across adjacent segments cancels it
    /// so the bubble never contracts and re-expands mid-bar.
    @State private var unhoverTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(data.segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .overlay {
                            if segment.isHatched {
                                DatalessHatchOverlay()
                            }
                        }
                        .frame(width: geometry.size.width * segment.fraction)
                        .onHover { hover(segment.id, isHovering: $0) }
                }
                // The empty track stands for free space; hover-sensitive so
                // it can answer with the available capacity.
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hover(Self.freeTrackID, isHovering: $0) }
            }
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(alignment: .topLeading) {
                // Mounted while `shownSegmentID` is set (through the whole
                // contract animation); only scale and opacity animate, so
                // the bubble always plays the same expand/contract in the
                // same segment-anchored place.
                if let info = shownInfo(barWidth: geometry.size.width) {
                    tooltip(
                        info: info,
                        barWidth: geometry.size.width,
                        isExpanded: hoveredSegmentID != nil
                    )
                }
            }
        }
        .frame(height: 5)
        .onPreferenceChange(VolumeBarTooltipSizeKey.self) { tooltipSize = $0 }
    }

    /// Entering expands the bubble; leaving contracts it after a short
    /// grace period, so hopping to the next segment (whose enter event may
    /// arrive after this one's exit) repositions the bubble instead of
    /// replaying the contract/expand cycle. Only the expanded/contracted
    /// flip is animated — content and position swap instantly.
    private func hover(_ id: String, isHovering: Bool) {
        if isHovering {
            unhoverTask?.cancel()
            unhoverTask = nil
            shownSegmentID = id
            if hoveredSegmentID == nil {
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28)) {
                    hoveredSegmentID = id
                }
            } else {
                hoveredSegmentID = id
            }
        } else if hoveredSegmentID == id {
            unhoverTask?.cancel()
            unhoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.14)) {
                    hoveredSegmentID = nil
                }
            }
        }
    }

    // MARK: - Tooltip

    private struct HoverInfo {
        let label: String
        let size: Int64
        /// Center of the hovered stretch, in bar coordinates.
        let midX: CGFloat
    }

    private func shownInfo(barWidth: CGFloat) -> HoverInfo? {
        guard let shownSegmentID else { return nil }
        if shownSegmentID == Self.freeTrackID {
            guard let available = data.availableSize, !data.segments.isEmpty else { return nil }
            let usedWidth = barWidth * data.segments.reduce(0) { $0 + $1.fraction }
            return HoverInfo(label: "Available", size: available, midX: (usedWidth + barWidth) / 2)
        }
        var x: CGFloat = 0
        for segment in data.segments {
            let width = barWidth * segment.fraction
            if segment.id == shownSegmentID {
                return HoverInfo(label: segment.label, size: segment.size, midX: x + (width / 2))
            }
            x += width
        }
        return nil
    }

    /// The bubble above the hovered stretch, macOS-storage-bar style. The
    /// bubble centers on the stretch but clamps to the bar's width; the
    /// tail keeps pointing at the stretch even when the bubble clamps.
    /// Offsets need the bubble's size, so it reports it via preference and
    /// hides until measured. Position is never animated: expand/contract is
    /// a scale out of the tail tip plus a fade, identical every time for a
    /// given segment.
    private func tooltip(info: HoverInfo, barWidth: CGFloat, isExpanded: Bool) -> some View {
        let width = tooltipSize.width
        let offsetX = min(max(info.midX - (width / 2), 0), max(barWidth - width, 0))
        let tailX = width > 0 ? info.midX - offsetX : nil
        let anchor: UnitPoint = if let tailX, width > 0 {
            UnitPoint(x: tailX / width, y: 1)
        } else {
            .bottom
        }
        return VolumeBarTooltip(
            label: info.label,
            size: info.size,
            tailX: tailX
        )
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: VolumeBarTooltipSizeKey.self, value: proxy.size)
        })
        .scaleEffect(isExpanded || reduceMotion ? 1 : 0.35, anchor: anchor)
        .opacity(tooltipSize == .zero || !isExpanded ? 0 : 1)
        .offset(x: offsetX, y: -(tooltipSize.height + Self.tooltipGap))
        .allowsHitTesting(false)
    }
}

private struct VolumeBarTooltipSizeKey: PreferenceKey {
    nonisolated static let defaultValue: CGSize = .zero

    nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// The hover bubble for one capacity-bar stretch: kind name over its size,
/// in a rounded bubble with a tail pointing down at the hovered spot.
private struct VolumeBarTooltip: View {
    static let tailHeight: CGFloat = 5

    let label: String
    let size: Int64
    /// Tail tip x in bubble coordinates; nil centers it (pre-measurement).
    let tailX: CGFloat?

    var body: some View {
        VStack(spacing: 1) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: NeodiskFormatters.size(size))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .padding(.bottom, Self.tailHeight)
        .background {
            let bubble = TooltipBubbleShape(tailHeight: Self.tailHeight, tailX: tailX)
            bubble
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(bubble.stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.22), radius: 3, y: 1)
        }
    }
}

/// Rounded rectangle with a downward tail at `tailX`, drawn as one path so
/// fill, stroke, and shadow stay continuous across the tail joint.
private struct TooltipBubbleShape: Shape {
    var cornerRadius: CGFloat = 7
    var tailWidth: CGFloat = 12
    var tailHeight: CGFloat
    /// Tail tip x; nil centers it. Clamped clear of the rounded corners.
    var tailX: CGFloat?

    nonisolated func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height - tailHeight
        )
        let halfTail = tailWidth / 2
        let minTip = rect.minX + cornerRadius + halfTail
        let maxTip = rect.maxX - cornerRadius - halfTail
        let tip = min(max(tailX ?? rect.midX, minTip), max(maxTip, minTip))
        var path = Path()
        path.addRoundedRect(
            in: body,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        path.move(to: CGPoint(x: tip - halfTail, y: body.maxY))
        path.addLine(to: CGPoint(x: tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: tip + halfTail, y: body.maxY))
        path.closeSubpath()
        return path
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
    /// Volume rows: the kind-colored capacity bar (empty track before any
    /// scan). Scanned cloud locations and folders: the on-this-Mac /
    /// cloud-only proportion bar.
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
