//
//  ContentView.swift
//  Neodisk
//
//  Root composition: welcome → scanning progress → the classic analyzer
//  workspace (outline | treemap | kind stats) with a status bar.
//

import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit

public struct ContentView: View {
    @Bindable var model: NeodiskViewModel
    @ObservedObject var preferences: AppPreferences
    let updates: UpdateController

    init(model: NeodiskViewModel, preferences: AppPreferences, updates: UpdateController) {
        self.model = model
        self.preferences = preferences
        self.updates = updates
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarPane(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            detailContent
                .dropDestination(for: URL.self) { urls, _ in
                    model.addDroppedFolders(urls)
                }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(SnapshotWindowHider())
        .sheet(isPresented: $model.showWelcomeSheet) {
            WelcomeSheet(model: model)
        }
        .onAppear {
            // This window can host the unobtrusive update indicator; while
            // any host window is up, the update driver stays out of dialogs.
            updates.viewModel.hostDidAppear()
            model.preferences = preferences
            if !preferences.hasSeenWelcome {
                model.showWelcomeSheet = true
            }
            // Dev/testing hook: NEODISK_AUTOSCAN=<path> scans on launch. A
            // connected cloud account's target ID (cloudscan://…) works too,
            // composing with NEODISK_CLOUD_FIXTURE for headless cloud runs.
            if let path = ProcessInfo.processInfo.environment["NEODISK_AUTOSCAN"],
               model.coordinator.phase == .idle {
                if let cloudTarget = model.cloudAccounts.accounts.first(where: { $0.id == path }) {
                    model.startScan(cloudTarget)
                } else {
                    model.startScan(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)))
                }
                // Dev/bench hook: NEODISK_BENCH_RESCANS drives repeated in-app
                // rescans of the just-started scan to measure felt rescan cost
                // with the baseline in memory (no relaunch/decode).
                BenchRescanDriver.shared.startIfRequested(model: model)
            }
            // Dev/testing hook: NEODISK_ANALYSIS_TAB=<kinds|largest|age|duplicates>
            // opens that statistics tab, so headless snapshots can capture
            // any tab.
            if let rawTab = ProcessInfo.processInfo.environment["NEODISK_ANALYSIS_TAB"],
               let tab = AnalysisTab(rawValue: rawTab) {
                model.analysisTab = tab
            }
            // Dev/testing hook: NEODISK_VIZ_MODE=<treemap|sunburst> picks the
            // center visualization without persisting a preference, so
            // headless snapshots can capture either view.
            if let rawMode = ProcessInfo.processInfo.environment["NEODISK_VIZ_MODE"],
               let mode = VizViewMode(rawValue: rawMode) {
                model.vizViewMode = mode
            }
            // Dev/testing hook: NEODISK_TREEMAP_STYLE=<cushion|flat> picks
            // the treemap style without persisting the preference, so
            // headless snapshots can capture either style.
            if let rawStyle = ProcessInfo.processInfo.environment["NEODISK_TREEMAP_STYLE"],
               let style = TreemapStyle(rawValue: rawStyle) {
                model.treemapStyle = style
            }
            // Dev/testing hook: NEODISK_UPDATE_STATE=<checking|available|
            // downloading|readyToInstall|upToDate|failed> forces the update
            // pill into a non-idle state at launch (with inert closures), so
            // headless snapshots can capture the toolbar indicator without a
            // live Sparkle check.
            if let rawUpdate = ProcessInfo.processInfo.environment["NEODISK_UPDATE_STATE"],
               let forced = UpdateState.devState(named: rawUpdate) {
                updates.viewModel.state = forced
            }
            // Dev/testing hook: NEODISK_AUTOREVEAL=<path> selects that node
            // once it is scanned, expanding its ancestors in the outline —
            // lets headless snapshots exercise deep trees and the
            // external-selection reveal path.
            if let revealPath = ProcessInfo.processInfo.environment["NEODISK_AUTOREVEAL"] {
                Task { @MainActor in
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(500))
                        if let node = Self.findNode(at: revealPath, in: model) {
                            model.select(node.id)
                            break
                        }
                    }
                }
            }
        }
        .onDisappear {
            updates.viewModel.hostDidDisappear()
        }
        // Full Disk Access gates the warning surfaces (panel and notice
        // strip). Recheck on activation: that is when the user comes back
        // from granting access in System Settings.
        .task {
            await model.warnings.refreshFullDiskAccessStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.warnings.refreshFullDiskAccessStatus() }
        }
        .toolbar { toolbarContent }
        .navigationTitle(windowTitle)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionErrorMessage != nil },
                set: { if !$0 { model.actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.coordinator.phase {
        case .idle:
            WelcomeView(model: model)
        case .restoring:
            SnapshotRestoreView(target: model.coordinator.selectedTarget)
        case .scanning, .displaying:
            // A partial tree arrives within a few hundred ms; from then on
            // the workspace renders live while the scan keeps running. One
            // case for both phases keeps WorkspaceView's SwiftUI identity
            // stable when the scan finishes — separate branches would tear
            // down and recreate the treemap view mid-session.
            if model.coordinator.snapshot != nil {
                WorkspaceView(model: model)
            } else if case .cachedWhileRefreshing = model.coordinator.displaySource {
                // A cached snapshot is decoding for display while the refresh
                // runs — a previously scanned location must never present as
                // a from-zero scan. If the decode fails, the coordinator
                // drops to .liveStreaming and the progress view takes over.
                SnapshotRestoreView(target: model.coordinator.selectedTarget)
            } else {
                ScanProgressView(model: model)
            }
        case .failed:
            ScanFailedView(model: model)
        }
    }

    /// Walks the scanned tree down to the node whose path matches, for the
    /// NEODISK_AUTOREVEAL dev hook.
    private static func findNode(at path: String, in model: NeodiskViewModel) -> FileNodeRecord? {
        guard let store = model.store else { return nil }
        var node = store.root
        while node.path != path {
            guard let child = store.children(of: node.id)
                .first(where: { path.hasPrefix($0.path + "/") || path == $0.path }) else {
                return nil
            }
            node = child
        }
        return node
    }

    private var windowTitle: String {
        Self.windowTitle(
            targetName: model.coordinator.selectedTarget?.displayName,
            targetKind: model.coordinator.selectedTarget?.kind,
            finderUsedBytes: model.freeSpace.finderUsedBytes,
            scannedTotalBytes: model.coordinator.snapshot?.aggregateStats.totalAllocatedSize
        )
    }

    /// Volume scans title the Finder/Disk Utility "used" figure (capacity
    /// minus available), so the window agrees with the rest of the system
    /// and with the sunburst legend header; folder and cloud scans title
    /// what the scan itself accounted for.
    nonisolated static func windowTitle(
        targetName: String?,
        targetKind: ScanTargetKind?,
        finderUsedBytes: Int64?,
        scannedTotalBytes: Int64?
    ) -> String {
        guard let targetName else { return "Neodisk" }
        let total: Int64? = if targetKind == .volume, let finderUsedBytes {
            finderUsedBytes
        } else {
            scannedTotalBytes
        }
        guard let total else { return targetName }
        return "\(targetName) (\(NeodiskFormatters.size(total)))"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            vizModePicker
        }
        // Cloud-only toggle sits beside the view switcher: it re-weights the
        // whole visualization, so it shares the picker's altitude. Persistent
        // but disabled when there is nothing for it to do (per the toolbar
        // contract in AGENTS.md).
        ToolbarItem(placement: .principal) {
            cloudOnlyToggle
        }

        // Update status pill kept visually separate from the trailing button
        // group. On macOS 26 every toolbar item in a logical group shares one
        // Liquid Glass capsule, which fuses the pill onto the button group and
        // makes that capsule grow when the pill appears. A ToolbarSpacer does
        // not break the grouping here; `sharedBackgroundVisibility(.hidden)`
        // does — it drops the pill out of the shared glass so it renders as
        // its own cluster (its own capsule, drawn by UpdateIndicator) with a
        // gap before the button group. Older systems have no shared-glass
        // grouping, so the pill is simply its own item ahead of the group.
        // Hidden while idle; once a check runs it persists until the user acts
        // on it (see UpdateIndicator).
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                UpdateIndicator(viewModel: updates.viewModel)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                trailingButtons
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                UpdateIndicator(viewModel: updates.viewModel)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                trailingButtons
            }
        }
    }

    /// The three mutually exclusive center views, flattened for the toolbar
    /// picker. Backed by the two persisted preferences (`vizViewMode` +
    /// `treemapStyle`): picking a treemap segment writes both; picking
    /// Sunburst leaves the treemap style untouched so switching back
    /// restores it.
    private enum VizChoice: Hashable {
        case cushion, flat, sunburst
    }

    private var vizChoice: Binding<VizChoice> {
        Binding(
            get: {
                if preferences.vizViewMode == .sunburst { return .sunburst }
                return preferences.treemapStyle == .flat ? .flat : .cushion
            },
            set: { choice in
                switch choice {
                case .cushion:
                    preferences.vizViewMode = .treemap
                    preferences.treemapStyle = .cushion
                case .flat:
                    preferences.vizViewMode = .treemap
                    preferences.treemapStyle = .flat
                case .sunburst:
                    preferences.vizViewMode = .sunburst
                }
            }
        )
    }

    private var vizModePicker: some View {
        Picker("View", selection: vizChoice) {
            Label("Cushion", systemImage: "square.split.bottomrightquarter")
                .tag(VizChoice.cushion)
            Label("Flat", systemImage: "rectangle.3.group")
                .tag(VizChoice.flat)
            Label("Sunburst", systemImage: "chart.pie")
                .tag(VizChoice.sunburst)
        }
        .pickerStyle(.segmented)
        .disabled(model.coordinator.snapshot == nil)
        .help("Switch between cushion treemap, flat treemap, and sunburst views")
    }

    private var cloudOnlyToggle: some View {
        Toggle(isOn: $preferences.showCloudOnlyFiles) {
            Label("Cloud-Only Files", systemImage: "cloud")
        }
        .toggleStyle(.button)
        .tint(model.snapshotHasCloudItems ? .accentColor : .secondary)
        .disabled(!model.snapshotHasCloudItems)
        .help(
            !model.snapshotHasCloudItems
                ? "No cloud-only files in this scan"
                : preferences.showCloudOnlyFiles
                    ? "Hide cloud-only files (files not downloaded from your cloud drives)"
                    : "Show cloud-only files (files not downloaded from your cloud drives)"
        )
    }

    @ViewBuilder
    private var trailingButtons: some View {
        // One fixed slot: Stop while a scan runs, Rescan otherwise
        // (grayed out until there is something to rescan).
        if model.coordinator.isScanning {
            Button {
                model.stopScan()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .help("Stop the current scan")
        } else {
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!model.coordinator.canRescan || model.coordinator.snapshot == nil)
            .help("Scan \(model.coordinator.selectedTarget?.displayName ?? "this location") again")
        }

        Button {
            model.showKindStats.toggle()
        } label: {
            Label("Statistics", systemImage: "sidebar.right")
        }
        .disabled(model.coordinator.snapshot == nil)
        .help(model.showKindStats ? "Hide the statistics panel" : "Show the statistics panel")

        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Open Neodisk settings")
    }
}

// MARK: - Workspace

private struct WorkspaceView: View {
    let model: NeodiskViewModel

    // Defaults leave the treemap clearly dominant on a fresh install's
    // default-size window; both panes stay user-resizable (persisted).
    @AppStorage("outlinePaneWidth") private var outlinePaneWidth = 300.0
    @AppStorage("kindStatsPaneWidth") private var kindStatsPaneWidth = 230.0

    private var permissionDeniedCount: Int {
        // With Full Disk Access granted the remaining unreadable locations
        // are protected for reasons no grant can fix, so the notice strip
        // (like the warnings panel) stays hidden.
        guard model.warnings.fullDiskAccessStatus != .granted,
              let snapshot = model.coordinator.snapshot, snapshot.isComplete else { return 0 }
        return snapshot.scanWarnings.count { $0.category == .permissionDenied }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    // The sunburst brings its own legend list; the outline
                    // pane would be a third redundant column, so it is
                    // treemap-only (the analysis pane behaves as always).
                    if model.vizViewMode != .sunburst {
                        OutlinePane(model: model)
                            .frame(width: outlinePaneWidth)

                        PaneSplitter(width: $outlinePaneWidth, range: 240...600, edge: .leading)
                    }

                    VStack(spacing: 0) {
                        // The flat treemap leans on the bar like the sunburst
                        // does: drilling is the only navigation, so the bar
                        // renders at its prominent size there too.
                        TreemapBreadcrumbBar(
                            model: model,
                            isProminent: model.vizViewMode == .sunburst
                                || model.treemapStyle == .flat
                        )
                        if model.vizViewMode == .sunburst {
                            SunburstPane(model: model)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            TreemapPane(model: model)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                    if model.showKindStats {
                        PaneSplitter(width: $kindStatsPaneWidth, range: 200...340, edge: .trailing)
                        AnalysisPane(model: model)
                            .frame(width: kindStatsPaneWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: model.showKindStats)
                .clipped()

                VStack(alignment: .trailing, spacing: 0) {
                    SnapshotNoticePanel(model: model)
                    WarningsPanel(model: model)
                }
                .animation(.easeInOut(duration: 0.2), value: model.warnings.visible.isEmpty)
                .animation(.easeInOut(duration: 0.2), value: model.session.snapshotNotice)
            }

            if model.coordinator.isScanning || model.scanWasStopped {
                Divider()
                LiveScanStrip(
                    progress: model.coordinator.progress,
                    isStopped: model.scanWasStopped,
                    cachedScanDate: model.coordinator.displayedCachedScanDate,
                    onStop: { model.stopScan() },
                    onResume: { model.resumeScan() }
                )
            } else if permissionDeniedCount > 0 {
                Divider()
                PermissionNoticeStrip(count: permissionDeniedCount)
            }

            Divider()
            StatusBar(model: model)
        }
    }
}

/// Shown after a scan that hit unreadable locations: totals are
/// underreported until the app gets Full Disk Access. Only mounted while
/// access is not granted (WorkspaceView zeroes the count otherwise), so it
/// always offers the Grant button.
private struct PermissionNoticeStrip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("\(count.formatted()) locations couldn't be read — sizes may be underreported.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Grant Full Disk Access…") {
                _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
            }
            .controlSize(.small)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Thin progress strip shown under the live map while the scan is running,
/// or after the user stops it (frozen bar + Resume).
private struct LiveScanStrip: View {
    @ObservedObject var progress: ScanProgressState
    var isStopped = false
    /// Finish date of the cached snapshot standing in for the running
    /// refresh scan; nil for ordinary scans.
    var cachedScanDate: Date?
    var onStop: (() -> Void)?
    var onResume: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            // Always determinate and monotonic: the bar never bounces. The
            // formerly "silent" phases (checking, merging) now either hold at
            // their current fraction with an explanatory caption or report real
            // sub-phase progress (the splice reports its copy/index/rebuild/
            // rebalance boundaries), so the bar only ever moves forward. The
            // drifting stripe sheen signals liveness during held fractions.
            StripedProgressBar(
                value: progress.metrics.progressFraction,
                isActive: !isStopped
            )
            .frame(width: 160)
            .opacity(isStopped ? 0.5 : 1)

            if isStopped {
                Button("Restart", action: { onResume?() })
                    .controlSize(.small)
            } else if let onStop {
                Button("Stop", action: onStop)
                    .controlSize(.small)
            }

            Text(statusText)
                .foregroundStyle(.secondary)
            // No counters have moved yet while checking for changes; "0 files"
            // next to that caption would read as lost data.
            if !progress.metrics.isCheckingChanges {
                Text("\(progress.metrics.filesVisited.formatted()) files · \(NeodiskFormatters.size(progress.metrics.bytesDiscovered))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if isStopped {
            return cachedScanDate != nil
                ? NSLocalizedString("Stopped — showing last scan", comment: "Live strip, stopped with a cached scan")
                : NSLocalizedString("Stopped — showing partial results", comment: "Live strip, stopped mid-scan")
        }
        // Activity phases outrank the cached-scan caption: the refresh path
        // is exactly where these silent phases used to look like a hang.
        if progress.metrics.isCheckingChanges {
            return NSLocalizedString("Checking for changes…", comment: "Live strip, incremental preparation")
        }
        if progress.metrics.isMergingChanges {
            return NSLocalizedString("Applying changes…", comment: "Live strip, incremental splice")
        }
        // An incremental refresh that degraded to a full scan says so, rather
        // than looking like a mysteriously long rescan. The root-relist path is
        // a normal incremental rescan and never sets this flag.
        if progress.metrics.isFullScanFallback {
            return NSLocalizedString("Changes too extensive — running a full scan…", comment: "Live strip, incremental rescan fell back to a full scan")
        }
        if let cachedScanDate {
            let relative = DisplayFormatters.relativeDate(cachedScanDate)
            return String(format: NSLocalizedString("Last scanned %@ — refreshing…", comment: "Live strip, refreshing a cached scan"), relative)
        }
        return progress.metrics.isFinalizing
            ? NSLocalizedString("Finishing up…", comment: "Live strip, finalizing")
            : NSLocalizedString("Scanning…", comment: "Live strip, scanning")
    }
}
