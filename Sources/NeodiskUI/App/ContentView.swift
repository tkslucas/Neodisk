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
            // NEODISK_* launch env hooks (autoscan, forced tab/view/style/
            // update state, autoreveal) — inert unless set. See DevLaunchHooks.
            DevLaunchHooks.apply(model: model, updates: updates)
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
    // default-size window; all panes stay user-resizable (persisted).
    // Bounds and window-aware clamping live in PaneLayout.
    @AppStorage("outlinePaneWidth")
    private var outlinePaneWidth = PaneLayout.outlineDefaultWidth
    @AppStorage("kindStatsPaneWidth")
    private var kindStatsPaneWidth = PaneLayout.analysisDefaultWidth
    @AppStorage("bottomOutlinePaneHeight")
    private var bottomOutlinePaneHeight = PaneLayout.bottomOutlineDefaultHeight

    private var fileListVisibility: WorkspaceFileListVisibility {
        WorkspaceFileListVisibility(
            viewMode: model.vizViewMode,
            treemapPosition: model.outlinePosition,
            showsBelowSunburst: model.showsFileListBelowSunburst
        )
    }

    private var warningCount: Int {
        model.warnings.visible.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane sizes are clamped against the actual workspace geometry
            // (WorkspacePaneMetrics), so the map keeps a usable size however
            // small the window gets and however wide the panes were dragged.
            GeometryReader { proxy in
                let metrics = paneMetrics(available: proxy.size)
                workspacePanes(metrics: metrics)
            }

            if let superseded = model.session.supersededScanNotice {
                Divider()
                SupersededScanStrip(displayName: superseded.displayName) {
                    model.session.supersededScanNotice = nil
                }
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
            } else if warningCount > 0 {
                Divider()
                ScanIssuesStrip(model: model, count: warningCount)
            }

            Divider()
            StatusBar(model: model)
        }
    }

    private func paneMetrics(available: CGSize) -> WorkspacePaneMetrics {
        WorkspacePaneMetrics(
            available: available,
            showsLeadingOutline: fileListVisibility.showsLeading,
            showsAnalysis: model.showKindStats,
            storedOutlineWidth: outlinePaneWidth,
            storedAnalysisWidth: kindStatsPaneWidth,
            storedBottomOutlineHeight: bottomOutlinePaneHeight
        )
    }

    private func workspacePanes(metrics: WorkspacePaneMetrics) -> some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                if fileListVisibility.showsLeading {
                    OutlinePane(model: model)
                        .frame(width: metrics.outlineWidth)

                    PaneSplitter(
                        size: $outlinePaneWidth,
                        range: metrics.outlineRange,
                        defaultSize: PaneLayout.outlineDefaultWidth,
                        paneEdge: .leading
                    )
                }

                VStack(spacing: 0) {
                    TreemapBreadcrumbBar(
                        model: model,
                        isProminent: model.vizViewMode == .sunburst
                    )
                    if model.vizViewMode == .sunburst {
                        SunburstPane(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TreemapPane(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Bottom dock: the wide multi-column file list sits
                    // under the map only — the analysis pane keeps its
                    // full height beside both.
                    if fileListVisibility.showsBottom {
                        PaneSplitter(
                            size: $bottomOutlinePaneHeight,
                            range: metrics.bottomOutlineRange,
                            defaultSize: PaneLayout.bottomOutlineDefaultHeight,
                            paneEdge: .bottom
                        )
                        BottomOutlinePane(model: model)
                            .frame(height: metrics.bottomOutlineHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if model.showKindStats {
                    PaneSplitter(
                        size: $kindStatsPaneWidth,
                        range: metrics.analysisRange,
                        defaultSize: PaneLayout.analysisDefaultWidth,
                        paneEdge: .trailing
                    )
                    AnalysisPane(model: model)
                        .frame(width: metrics.analysisWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: model.showKindStats)
            .clipped()

            SnapshotNoticePanel(model: model)
                .animation(.easeInOut(duration: 0.2), value: model.session.snapshotNotice)
        }
    }
}

/// Shown after a scan that hit unreadable locations: totals are
/// underreported until every location can be read. Clicking opens the
/// grouped details popover; the inline Full Disk Access shortcut appears
/// only when granting would actually unlock a failed path.
private struct ScanIssuesStrip: View {
    let model: NeodiskViewModel
    let count: Int

    @State private var showingDetails = false

    private var allPermissionDenied: Bool {
        model.warnings.visible.allSatisfy { $0.category == .permissionDenied }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingDetails.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: allPermissionDenied ? "lock.fill" : "exclamationmark.triangle.fill")
                    Text("\(count.formatted()) locations couldn't be read — sizes may be underreported.")
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                ScanIssuesPopover(model: model)
            }
            if model.warnings.suggestFullDiskAccess {
                Button("Grant Full Disk Access…") {
                    _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// The strip's on-demand detail: one row per failed ancestor with a member
/// count, exact paths and errors in the row tooltip.
private struct ScanIssuesPopover: View {
    let model: NeodiskViewModel

    var body: some View {
        let groups = model.warnings.groups
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        HStack(spacing: 8) {
                            Image(systemName: group.isPermissionDenied
                                ? "lock.fill"
                                : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text((group.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(group.count.formatted())
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .help(group.details.joined(separator: "\n"))
                    }
                }
                .padding(.vertical, 6)
            }
            // ScrollView greedily fills a proposed max height, so size it to
            // the rows and clamp instead of leaving dead space under few rows.
            .frame(height: min(280, CGFloat(groups.count) * 27 + 12))
        }
        .frame(width: 340)
    }
}

/// Passive one-line mention shown when an explicit new scan took a contended
/// disk from a scan the app stopped for it. Dismissable; clears on its own
/// when the new scan finishes.
private struct SupersededScanStrip: View {
    let displayName: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
            Text(String(format: NSLocalizedString(
                "Stopped scanning %@ to start the new scan.",
                comment: "Passive strip, an explicit scan stopped another on the same disk"
            ), displayName))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
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
