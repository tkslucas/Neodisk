// Locations sidebar: mounted volumes (each with a kind-colored capacity bar), detected cloud storage folders, one
// flat Folders section (the common folders, extended by Add Folder, every row removable), and Cleanup. One click
// scans. Sections collapse from their header; right-clicking a header picks the sections shown.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct SidebarPane: View {
    let model: NeodiskViewModel

    @State private var selection: Set<String> = []
    @State private var spaceByPath: [String: VolumeSpaceInfo] = [:]
    @State private var kindBars: [String: VolumeBarData] = [:]
    /// Frames and hover state for the bars' hover bubbles, which the List
    /// overlay renders so table cells cannot clip them. Deliberately `@State`
    /// and not `@StateObject`: the pane owns the store's lifetime but must
    /// not subscribe to its per-scroll-tick churn — only the overlay's
    /// `SidebarTooltipLayer` observes it.
    @State private var tooltips = SidebarTooltipStore()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.neoTextScale) private var textScale
    /// The window's: removing folders from the sidebar is undoable.
    @Environment(\.undoManager) private var undoManager

    /// Sidebar folders, minus any that duplicate a built-in location.
    private var visibleFolders: [ScanTarget] {
        let builtInIDs = Set(model.builtInLocations.map(\.id))
        return model.sidebarFolders.filter { !builtInIDs.contains($0.id) }
    }

    var body: some View {
        // The timeline date flows into the rows so "Scanned … ago" refreshes each minute. Cleanup sits below the list
        // (an inset would let rows scroll behind it) and is laid out first, so the list gives up the room.
        VStack(spacing: 0) {
            TimelineView(.everyMinute) { context in
                sidebarList(now: context.date)
            }
            if model.isSidebarSectionShown(.cleanup), model.coordinator.snapshot != nil {
                CleanupPanel(model: model)
                    .layoutPriority(1)
                    // Its empty drop area answers a right-click like the list's empty space.
                    .contextMenu { SidebarSectionsMenuItems(model: model) }
            }
        }
    }

    private func expansion(of section: SidebarSection) -> Binding<Bool> {
        Binding(
            get: { model.sidebarSections.isExpanded(section) },
            set: { model.setSidebarSection(section, expanded: $0) }
        )
    }

    /// A collapsible section whose header offers the sections menu.
    private func section(
        _ section: SidebarSection, @ViewBuilder content: () -> some View
    ) -> some View {
        let isExpanded = expansion(of: section)
        return Section(isExpanded: isExpanded) {
            content()
        } header: {
            // Scales with the rows; the system's header font wouldn't. The whole header toggles, not just its chevron.
            Text(LocalizedStringKey(section.titleKey))
                .neoFont(11, weight: .bold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { isExpanded.wrappedValue.toggle() } }
                .contextMenu { SidebarSectionsMenuItems(model: model) }
        }
    }

    private func sidebarList(now: Date) -> some View {
        List(selection: $selection) {
            if model.isSidebarSectionShown(.volumes) {
                section(.volumes) {
                    ForEach(model.volumeLocations) { target in
                        builtInLocationRow(target, now: now, bar: kindBars[target.id] ?? .empty)
                    }
                }
            }

            if model.isSidebarSectionShown(.cloudFiles), !model.cloudLocations.isEmpty {
                section(.cloudFiles) {
                    ForEach(model.cloudLocations) { target in
                        builtInLocationRow(target, now: now, bar: cloudBar(for: target))
                    }
                }
            }

            if model.isSidebarSectionShown(.folders) {
                section(.folders) {
                    ForEach(visibleFolders) { target in
                        row(target, now: now, bar: cloudBar(for: target) ?? kindBars[target.id])
                            .contextMenu { rowMenu(for: target, removable: true) }
                    }

                    addFolderRow
                }
            }
        }
        .listStyle(.sidebar)
        // Right-clicking empty space offers the sections, so a hidden one can always come back. Rows keep their own menus.
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty {
                SidebarSectionsMenuItems(model: model)
            }
        }
        .overlay {
            SidebarTooltipLayer(
                store: tooltips,
                progressFor: backgroundScanProgress(forTargetID:)
            )
        }
        .addLocationDropTarget(model: model)
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
            // modifier clicks only adjust the selection. Arrow keys only show what's saved: Return opens the rest.
            let event = NSApp.currentEvent
            let modifiers = event?.modifierFlags ?? []
            guard newSelection.count == 1,
                  let targetID = newSelection.first,
                  !modifiers.contains(.command),
                  !modifiers.contains(.shift),
                  targetID != model.coordinator.selectedTarget?.id || model.fullDiskAccessGate != nil,
                  let target = allTargets.first(where: { $0.id == targetID }) else {
                return
            }
            if event?.type == .keyDown {
                model.startScan(target, previewOnly: true)
            } else {
                model.startChosenScan(target)
            }
        }
        .onKeyPress(.return) {
            guard selection.count == 1, let targetID = selection.first,
                  targetID != model.coordinator.selectedTarget?.id,
                  let target = allTargets.first(where: { $0.id == targetID }) else { return .ignored }
            model.startChosenScan(target)
            return .handled
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
        .task(id: kindBarsTaskID) {
            await loadVolumeSpace()
            await loadKindBars()
        }
    }

    private var allTargets: [ScanTarget] {
        model.builtInLocations + visibleFolders
    }

    /// A background scan running for this location — the demoted scans in the
    /// session registry, NOT the foreground displayed one (that has the full
    /// scan page). Reading the registry ties the list to scan start/stop only:
    /// the dictionary changes identity on insert/remove, while progress ticks
    /// mutate each session's own `ScanProgressState`, which the leaf
    /// `SidebarScanBar` observes in isolation.
    private func backgroundScanProgress(for target: ScanTarget) -> ScanProgressState? {
        backgroundScanProgress(forTargetID: target.id)
    }

    private func backgroundScanProgress(forTargetID targetID: String) -> ScanProgressState? {
        guard let session = model.session.activeSessions[targetID], session.state == .running else {
            return nil
        }
        return session.progress
    }

    private func updateScanBarFrame(targetID: String, frame: CGRect?) {
        tooltips.setFrame(frame, forTargetID: targetID)
    }

    private func updateScanBarHover(targetID: String, isHovering: Bool) {
        tooltips.setHovering(isHovering, targetID: targetID, reduceMotion: reduceMotion)
    }

    /// True while any scan (foreground or background) runs for this location.
    private func isScanning(_ targetID: String) -> Bool {
        model.session.activeSession(forTargetID: targetID) != nil
    }

    /// The last Folders row: a quiet item on the rows' icon and name columns, not a button slab inside the list.
    private var addFolderRow: some View {
        Button {
            model.chooseFolderAndScan()
        } label: {
            HStack(spacing: (8 * textScale).rounded()) {
                Image(systemName: "plus.circle")
                    .neoFont(15)
                    .frame(width: (22 * textScale).rounded())
                Text("Add Folder…")
                    .neoFont(13)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Scan any folder or volume and keep it in the sidebar")
    }

    private func row(_ target: ScanTarget, now: Date, bar: VolumeBarData?) -> some View {
        let space = target.kind == .volume ? spaceByPath[target.id] : nil
        let info = model.session.cachedScanInfo[target.id]
        return SidebarTargetRow(
            target: target,
            size: SidebarRowText.size(
                space: space,
                scannedBytes: info?.totalAllocatedSize,
                unreadable: info?.totalAllocatedSize == 0 && wasRefused(target)
            ),
            lastScanned: info?.lastScanDate,
            now: now,
            isSelected: selection.contains(target.id),
            usage: SidebarRowText.usage(space: space),
            bar: bar,
            scanProgress: backgroundScanProgress(for: target),
            onScanBarFrameChange: updateScanBarFrame,
            onScanBarHover: updateScanBarHover,
            onCapacityBubble: tooltips.setCapacityBubble
        )
        .tag(target.id)
    }

    /// A scan that came back empty because the location itself refused access, as far as this session's scans
    /// tell (an empty folder reads its size instead).
    private func wasRefused(_ target: ScanTarget) -> Bool {
        let snapshot = model.coordinator.snapshot?.target.id == target.id
            ? model.coordinator.snapshot
            : model.coordinator.recentSnapshot(forTargetID: target.id)
        return snapshot?.scanWarnings.contains {
            $0.category == .permissionDenied && ScanTarget(url: URL(filePath: $0.path)).id == target.id
        } ?? false
    }

    /// One row of the Volumes or Local Cloud Files section: not removable.
    private func builtInLocationRow(
        _ target: ScanTarget,
        now: Date,
        bar: VolumeBarData?
    ) -> some View {
        row(target, now: now, bar: bar)
            .contextMenu { rowMenu(for: target, removable: false) }
    }

    private var selectedFolderIDs: Set<String> {
        selection.intersection(visibleFolders.map(\.id))
    }

    /// A row's menu: scan it fresh (or stop its background scan), reveal it, and for Folders rows remove it.
    @ViewBuilder
    private func rowMenu(for target: ScanTarget, removable: Bool) -> some View {
        if model.session.activeSessions[target.id] != nil, target.id != model.coordinator.selectedTarget?.id {
            // A background scan; the displayed one has the scan page's own stop control.
            Button("Stop Scan") {
                model.session.stopSession(forTargetID: target.id)
            }
        } else {
            Button(model.session.cachedScanInfo[target.id] == nil ? "Scan" : "Rescan") {
                model.startScan(target, forcesRescan: true)
            }
            .disabled(isScanning(target.id))
        }
        Divider()
        Button("Reveal in Finder") {
            SystemIntegration.reveal(target.url)
        }
        if removable {
            let ids = selectedFolderIDs.contains(target.id) ? selectedFolderIDs : [target.id]
            Divider()
            // Refuse removal while a scan is in flight — dropping the cache mid-scan would orphan the session (the
            // model guard backs this). A bulk remove stays live as long as one selected folder is idle.
            Button(ids.count > 1 ? "Remove \(ids.count) Folders from Sidebar" : "Remove from Sidebar") {
                model.removeSidebarFolders(ids: ids, undoManager: undoManager)
                selection.subtract(ids)
            }
            .disabled(ids.allSatisfy { isScanning($0) })
        }
    }

    private func removeSelectedFolders() {
        let ids = selectedFolderIDs
        guard !ids.isEmpty else { return }
        model.removeSidebarFolders(ids: ids, undoManager: undoManager)
        selection.subtract(ids)
    }

    /// The on-this-Mac / cloud-only bar under scanned cloud locations and
    /// folders — straight from the cache index, no snapshot decode. Volume
    /// rows keep their kind-colored capacity bar instead, and folders without
    /// cloud-only files their kinds bar.
    private func cloudBar(for target: ScanTarget) -> VolumeBarData? {
        guard let info = model.session.cachedScanInfo[target.id] else { return nil }
        return VolumeBarData.cloudProportions(
            onThisMac: info.totalAllocatedSize,
            cloudOnly: info.cloudOnlyLogicalSize
        )
    }

    // MARK: - Kind bars

    /// Reloads whenever a sidecar lands or the palette changes. The
    /// sidecar generation — not the scan date — is the fresh-scan trigger:
    /// the sidecar is written asynchronously after the save that updates
    /// `cachedScanInfo`, so a date-keyed reload would run too early, find
    /// no sidecar, and leave the bar empty until the next scan.
    private var kindBarsTaskID: String {
        let scans = (model.volumeLocations + visibleFolders).map { target in
            "\(target.id)|\(model.session.cachedScanInfo[target.id].map(\.lastScanDate.timeIntervalSince1970) ?? 0)"
        }
        return scans.joined(separator: ",")
            + "|\(model.session.kindStatsSidecarGeneration)"
            + "|\(model.vizPalette.id)"
    }

    /// Free space for every volume row, Folders' added volumes included, refreshed with the bars.
    private func loadVolumeSpace() async {
        let urls = (model.volumeLocations + visibleFolders).filter { $0.kind == .volume }.map { ($0.id, $0.url) }
        spaceByPath = await Task.detached(priority: .utility) {
            var spaces: [String: VolumeSpaceInfo] = [:]
            for (id, url) in urls {
                spaces[id] = VolumeSpaceInfo.load(for: url)
            }
            return spaces
        }.value
    }

    private func loadKindBars() async {
        let palette = model.vizPalette
        var bars: [String: VolumeBarData] = [:]
        for target in model.volumeLocations + visibleFolders {
            // Never scanned → the bar stays an empty track (no sidecar to
            // color it, and no misleading half-answer from volume stats).
            guard let info = model.session.cachedScanInfo[target.id] else { continue }
            guard let sidecar = await model.session.loadKindStatsSidecar(forTargetID: target.id) else {
                continue
            }
            let scannedBytes = info.totalAllocatedSize
            let isVolume = target.kind == .volume
            let space = spaceByPath[target.id]
            bars[target.id] = await Task.detached(priority: .utility) {
                isVolume
                    ? VolumeBarData.make(
                        space: space,
                        sidecar: sidecar,
                        scannedBytes: scannedBytes,
                        palette: palette
                    )
                    : VolumeBarData.composition(sidecar: sidecar, scannedBytes: scannedBytes, palette: palette)
            }.value
        }
        kindBars = bars
    }
}

/// The sections checklist, shared by the headers' menus and View > Sidebar Sections.
struct SidebarSectionsMenuItems: View {
    let model: NeodiskViewModel

    var body: some View {
        // A section is offered only where it can show: Local Cloud Files where there are some, Cleanup with a scan
        // on screen and moving to the Trash allowed.
        let sections = SidebarSection.allCases.filter { section in
            switch section {
            case .cloudFiles: !model.cloudLocations.isEmpty
            case .cleanup: model.cleanup.isEnabled && model.coordinator.snapshot != nil
            default: true
            }
        }
        ForEach(sections, id: \.self) { section in
            Toggle(LocalizedStringKey(section.titleKey), isOn: Binding(
                get: { model.isSidebarSectionShown(section) },
                set: { model.setSidebarSection(section, shown: $0) }
            ))
        }
    }
}
