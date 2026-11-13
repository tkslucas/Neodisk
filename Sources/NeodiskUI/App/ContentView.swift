// Root composition: welcome → scanning progress → the classic analyzer
// workspace (outline | treemap | kind stats) with a status bar.

import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit
import NeodiskAppModel

public struct ContentView: View {
    @Bindable var model: NeodiskViewModel
    @ObservedObject var preferences: AppPreferences
    let updates: UpdateController

    init(model: NeodiskViewModel, preferences: AppPreferences, updates: UpdateController) {
        self.model = model
        self.preferences = preferences
        self.updates = updates
    }

    private var textScale: CGFloat { CGFloat(model.textScale) }

    private var minimumSize: CGSize {
        PaneLayout.windowMinSize(scale: model.textScale, screen: NSScreen.main?.visibleFrame.size)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarPane(model: model)
                .navigationSplitViewColumnWidth(
                    min: PaneLayout.sidebarMinWidth(scale: model.textScale),
                    ideal: PaneLayout.sidebarIdealWidth(scale: model.textScale),
                    max: PaneLayout.sidebarMaxWidth(scale: model.textScale)
                )
                .neoWorkspaceText(scale: textScale)
        } detail: {
            detailContent
                .addLocationDropTarget(model: model)
                .neoWorkspaceText(scale: textScale)
                // On the detail column, not the split view: there, macOS 26 puts toolbar spacers in the sidebar's
                // section, ahead of every item, so none separated anything. Outside the text scale, as chrome.
                .toolbar { toolbarContent }
        }
        // The workspace text scale enters in each column and the welcome sheet; other scenes (Settings, About) and
        // the window's chrome keep the system size.
        .frame(
            minWidth: minimumSize.width,
            minHeight: minimumSize.height
        )
        .background(SnapshotWindowHider())
        .background(ToolbarButtonRefresher(state: [
            model.coordinator.isScanning, model.canRescan, model.coordinator.snapshot != nil, model.cleanup.isEnabled,
        ]))
        .sheet(isPresented: $model.showWelcomeSheet) {
            WelcomeSheet(model: model)
                .neoWorkspaceText(scale: textScale)
        }
        .onAppear {
            // This window can host the unobtrusive update indicator; while
            // any host window is up, the update driver stays out of dialogs.
            updates.viewModel.hostDidAppear()
            if !preferences.hasSeenWelcome {
                model.showWelcomeSheet = true
            }
            // NEODISK_* launch env hooks (autoscan, forced tab/view/style/
            // update state, autoreveal) — inert unless set. See DevLaunchHooks.
            FeltTiming.markLaunch("contentAppeared")
            DevLaunchHooks.apply(model: model, updates: updates)
        }
        .onDisappear {
            updates.viewModel.hostDidDisappear()
        }
        // Recheck on activation: that's when the user returns from granting access in System Settings.
        .task {
            await model.warnings.refreshFullDiskAccessStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.warnings.refreshFullDiskAccessStatus() }
        }
        .onChange(of: model.warnings.fullDiskAccessStatus) { _, status in
            if status == .granted { model.passFullDiskAccessGate(remembering: false) }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
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
        if model.fullDiskAccessGate != nil {
            FullDiskAccessGateView(model: model)
        } else {
            phaseContent
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.coordinator.phase {
        case .idle:
            WelcomeView(model: model)
        case .restoring:
            SnapshotRestoreView(target: model.coordinator.selectedTarget)
        case .scanning, .displaying:
            // One case for both phases keeps WorkspaceView's identity stable when the scan finishes;
            // separate branches would recreate the treemap view mid-session.
            if model.coordinator.snapshot != nil {
                WorkspaceView(model: model)
            } else if case .cachedWhileRefreshing = model.coordinator.displaySource {
                // A previously scanned location must never present as a from-zero scan while its cache decodes.
                SnapshotRestoreView(target: model.coordinator.selectedTarget)
            } else {
                ScanProgressView(model: model)
            }
        case .failed:
            ScanFailedView(model: model)
        }
    }

    /// The location in the title, its size in the subtitle beneath it.
    private var windowTitle: String {
        (model.fullDiskAccessGate ?? model.coordinator.selectedTarget)?.displayName ?? AppChannel.current.appName
    }

    private var windowSubtitle: String {
        guard model.fullDiskAccessGate == nil else { return "" }
        return Self.windowSubtitle(
            targetKind: model.coordinator.selectedTarget?.kind,
            finderUsedBytes: model.freeSpace.finderUsedBytes,
            freeBytes: model.freeSpace.freeSpaceBytes,
            scannedTotalBytes: model.coordinator.snapshot?.aggregateStats.totalAllocatedSize
        )
    }

    /// A volume states the system's used, capacity and free figures, so the window agrees with Finder and the
    /// legend; a folder states what the scan accounted for.
    nonisolated static func windowSubtitle(
        targetKind: ScanTargetKind?,
        finderUsedBytes: Int64?,
        freeBytes: Int64?,
        scannedTotalBytes: Int64?
    ) -> String {
        if targetKind == .volume, let finderUsedBytes {
            guard let freeBytes else { return NeodiskFormatters.size(finderUsedBytes) }
            return String(
                format: NSLocalizedString("%@ of %@ used · %@ free", comment: "Window subtitle for a scanned volume"),
                NeodiskFormatters.size(finderUsedBytes),
                NeodiskFormatters.size(finderUsedBytes + freeBytes),
                NeodiskFormatters.size(freeBytes)
            )
        }
        return scannedTotalBytes.map(NeodiskFormatters.size) ?? ""
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            vizModePicker
        }
        // Only scans with cloud-only files have anything for it to weigh. A filter, not a view: on macOS 26 a
        // spacer keeps it out of the picker's glass capsule.
        if model.snapshotHasCloudItems {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .principal)
            }
            ToolbarItem(placement: .principal) {
                cloudOnlyToggle
            }
        }

        // On macOS 26 grouped toolbar items share one glass capsule, which fused the pill onto the buttons;
        // `sharedBackgroundVisibility(.hidden)` separates it (a ToolbarSpacer does not).
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

    private var vizModePicker: some View {
        VizViewPicker(
            views: model.layout.views,
            current: model.vizView,
            isEnabled: model.coordinator.snapshot != nil,
            update: model.updateLayout,
            menuItems: { NSMenu.workspaceLayoutItems(model: model) }
        )
    }

    private var cloudOnlyToggle: some View {
        Toggle(isOn: $preferences.showCloudOnlyFiles) {
            Label("Cloud-Only Files", systemImage: "cloud")
        }
        .toggleStyle(.button)
        .neoHelp(
            preferences.showCloudOnlyFiles
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
            .neoHelp("Stop the current scan")
        } else {
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canRescan)
            .neoHelp("Scan \(model.coordinator.selectedTarget?.displayName ?? "this location") again")
        }

        // Removed, not disabled, while moving to the Trash is off.
        if model.cleanup.isEnabled {
            CleanupToolbarButton(model: model)
        }

        Button {
            model.showKindStats.toggle()
        } label: {
            Label("Statistics", systemImage: "sidebar.right")
        }
        .disabled(model.coordinator.snapshot == nil)
        .neoHelp(model.showKindStats ? "Hide the statistics panel" : "Show the statistics panel")

        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }
        .neoHelp("Open Neodisk settings")
    }
}

// MARK: - Workspace

private struct WorkspaceView: View {
    let model: NeodiskViewModel

    // Defaults leave the treemap dominant on a fresh window; bounds and clamping live in PaneLayout.
    @AppStorage("outlinePaneWidth")
    private var outlinePaneWidth = PaneLayout.outlineDefaultWidth()
    @AppStorage("kindStatsPaneWidth")
    private var kindStatsPaneWidth = PaneLayout.analysisDefaultWidth()
    @AppStorage("bottomOutlinePaneHeight")
    private var bottomOutlinePaneHeight = PaneLayout.bottomOutlineDefaultHeight()

    // AppStorage writes synchronize through UserDefaults. Keep pointer-drag
    // deltas local, then persist only the final size when the gesture ends.
    @State private var transientOutlinePaneWidth: Double?
    @State private var transientKindStatsPaneWidth: Double?
    @State private var transientBottomOutlinePaneHeight: Double?


    private var warningCount: Int {
        model.warnings.visible.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Clamped against the real geometry so the map stays usable however small the window or wide the
            // panes.
            GeometryReader { proxy in
                let metrics = paneMetrics(available: proxy.size)
                workspacePanes(metrics: metrics)
            }

            bottomStrips
                // Without the status bar under them, the last strip meets the window's rounded bottom edge.
                .padding(.bottom, model.showsStatusBar || !hasBottomStrip ? 0 : 5)

            if model.showsStatusBar {
                Divider()
                StatusBar(model: model)
                    .contextMenu { WorkspaceLayoutMenuItems(model: model) }
            }
        }
        // The snapshot strip slides in and out instead of jumping the map under the pointer.
        .animation(.easeInOut(duration: 0.2), value: model.session.snapshotNotice == nil)
    }

    private var hasBottomStrip: Bool {
        model.session.snapshotNotice != nil || model.session.supersededScanNotice != nil
            || model.coordinator.isScanning || model.scanWasStopped || warningCount > 0
    }

    private var bottomStrips: some View {
        VStack(spacing: 0) {
            if let notice = model.session.snapshotNotice {
                VStack(spacing: 0) {
                    Divider()
                    SnapshotNoticeStrip(model: model, notice: notice)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        }
    }

    private func paneMetrics(available: CGSize) -> WorkspacePaneMetrics {
        WorkspacePaneMetrics(
            available: available,
            showsLeadingOutline: model.layout.showsLeadingList,
            showsAnalysis: model.showKindStats,
            storedOutlineWidth: transientOutlinePaneWidth ?? outlinePaneWidth,
            storedAnalysisWidth: transientKindStatsPaneWidth ?? kindStatsPaneWidth,
            storedBottomOutlineHeight: transientBottomOutlinePaneHeight
                ?? bottomOutlinePaneHeight,
            textScale: model.textScale
        )
    }

    private var outlinePaneSize: Binding<Double> {
        Binding(
            get: { transientOutlinePaneWidth ?? outlinePaneWidth },
            set: { transientOutlinePaneWidth = $0 }
        )
    }

    private var kindStatsPaneSize: Binding<Double> {
        Binding(
            get: { transientKindStatsPaneWidth ?? kindStatsPaneWidth },
            set: { transientKindStatsPaneWidth = $0 }
        )
    }

    private var bottomOutlinePaneSize: Binding<Double> {
        Binding(
            get: { transientBottomOutlinePaneHeight ?? bottomOutlinePaneHeight },
            set: { transientBottomOutlinePaneHeight = $0 }
        )
    }

    private func workspacePanes(metrics: WorkspacePaneMetrics) -> some View {
        Group {
            HStack(spacing: 0) {
                if model.layout.showsLeadingList {
                    OutlinePane(model: model)
                        .frame(width: metrics.outlineWidth)

                    PaneSplitter(
                        size: outlinePaneSize,
                        range: metrics.outlineRange,
                        defaultSize: PaneLayout.outlineDefaultWidth(scale: model.textScale),
                        paneEdge: .leading,
                        onCommit: {
                            outlinePaneWidth = $0
                            transientOutlinePaneWidth = nil
                        }
                    )
                }

                VStack(spacing: 0) {
                    // The sunburst floats its own over the chart's free corner.
                    if model.vizViewMode != .sunburst {
                        TreemapBreadcrumbBar(model: model)
                    }
                    if model.vizViewMode == .sunburst {
                        SunburstPane(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TreemapPane(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // The bottom dock sits under the map only; the analysis pane keeps its full height.
                    if model.layout.showsBottomList {
                        PaneSplitter(
                            size: bottomOutlinePaneSize,
                            range: metrics.bottomOutlineRange,
                            defaultSize: PaneLayout.bottomOutlineDefaultHeight(scale: model.textScale),
                            paneEdge: .bottom,
                            onCommit: {
                                bottomOutlinePaneHeight = $0
                                transientBottomOutlinePaneHeight = nil
                            }
                        )
                        BottomOutlinePane(model: model)
                            .frame(height: metrics.bottomOutlineHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                // Always docked, beside the map and never over it, so its edge is a divider like the others.
                if model.showKindStats {
                    PaneSplitter(
                        size: kindStatsPaneSize,
                        range: metrics.analysisRange,
                        defaultSize: PaneLayout.analysisDefaultWidth(scale: model.textScale),
                        paneEdge: .trailing,
                        onCommit: {
                            kindStatsPaneWidth = $0
                            transientKindStatsPaneWidth = nil
                        }
                    )
                    AnalysisPane(model: model)
                        .frame(width: metrics.analysisWidth)
                }
            }
            // The statistics panel shows and hides at once, unanimated: a sliding panel resized the map and the
            // file list on every frame, redrawing the sunburst and the tables each time (200-300 ms stalls, and a
            // 1.7 s freeze on a big scan).
            .clipped()
        }
    }
}

/// The inline Full Disk Access shortcut appears only when granting would unlock a failed path.
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
                    Text(AppStrings.plural(
                        count,
                        one: "%@ location couldn't be read — sizes may be underreported.",
                        other: "%@ locations couldn't be read — sizes may be underreported.",
                        count.formatted()
                    ))
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .neoFont(8, weight: .semibold)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                ScanIssuesPopover(model: model)
            }
            if model.warnings.suggestFullDiskAccess {
                Button {
                    _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
                } label: {
                    Text("Grant Full Disk Access…").neoFont(11)
                }
                .neoControlSize(base: .small)
            }
            Spacer()
        }
        .neoFont(11)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// The strip's on-demand detail: one row per failed ancestor with a member
/// count, exact paths and errors in the row tooltip.
private struct ScanIssuesPopover: View {
    @Environment(\.neoTextScale) private var textScale

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
                                .neoFont(10)
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text((group.path as NSString).abbreviatingWithTildeInPath)
                                .neoFont(11, weight: .medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(group.count.formatted())
                                .neoFont(11)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .neoHelp(group.details.joined(separator: "\n"))
                    }
                }
                .padding(.vertical, 6)
            }
            // ScrollView greedily fills a proposed max height, so size it to
            // the rows and clamp instead of leaving dead space under few rows.
            .frame(height: min(280 * textScale, CGFloat(groups.count) * 27 * textScale + 12))
        }
        .frame(width: 340 * textScale)
    }
}

/// Shown when a new scan took a contended disk from a scan the app stopped; clears when it finishes.
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
            .neoHelp("Dismiss")
        }
        .neoFont(11)
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

    @Environment(\.neoTextScale) private var textScale

    var body: some View {
        // Reads like the status bar below it: what's happening leading, the bar and its button at the trailing end.
        HStack(spacing: 10) {
            // The caption says what's happening, so it gives way last: the counts go first, then the bar narrows.
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(2)
            // No counters have moved yet while checking for changes; "0 files"
            // next to that caption would read as lost data.
            if !progress.metrics.isCheckingChanges {
                ViewThatFits(in: .horizontal) {
                    Text(AppStrings.plural(
                        progress.metrics.filesVisited, one: "%@ file · %@", other: "%@ files · %@",
                        progress.metrics.filesVisited.formatted(), NeodiskFormatters.size(progress.metrics.bytesDiscovered)
                    ))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            }
            Spacer(minLength: 12)

            // Always determinate and monotonic: held phases keep their fraction with a caption, and the stripe
            // sheen signals liveness meanwhile.
            StripedProgressBar(
                value: progress.metrics.progressFraction,
                isActive: !isStopped
            )
            .frame(minWidth: (80 * textScale).rounded(), maxWidth: (160 * textScale).rounded())
            .opacity(isStopped ? 0.5 : 1)

            if isStopped {
                Button { onResume?() } label: { Text("Restart").neoFont(11) }
                    .neoControlSize(base: .small)
            } else if let onStop {
                Button(action: onStop) { Text("Stop").neoFont(11) }
                    .neoControlSize(base: .small)
            }
        }
        .neoFont(11)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if isStopped {
            return cachedScanDate != nil
                ? NSLocalizedString("Stopped — showing last scan", comment: "Live strip, stopped with a cached scan")
                : NSLocalizedString("Stopped — showing partial results", comment: "Live strip, stopped mid-scan")
        }
        // The one wait only the user can end comes first.
        if let permissionWaitText = progress.permissionWaitText {
            return permissionWaitText
        }
        // Activity phases outrank the cached-scan caption: the refresh path
        // is exactly where these silent phases used to look like a hang.
        if progress.metrics.isCheckingChanges {
            return NSLocalizedString("Checking for changes…", comment: "Live strip, incremental preparation")
        }
        if progress.metrics.isMergingChanges {
            return NSLocalizedString("Applying changes…", comment: "Live strip, incremental splice")
        }
        // A fallback to a full scan says so rather than looking like a mysteriously long rescan.
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
