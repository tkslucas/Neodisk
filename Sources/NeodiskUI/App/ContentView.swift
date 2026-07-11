//
//  ContentView.swift
//  Neodisk
//
//  Root composition: welcome → scanning progress → the Disk Inventory X-style
//  workspace (outline | treemap | kind stats) with a status bar.
//

import AppKit
import SwiftUI
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
            // Dev/testing hook: NEODISK_AUTOSCAN=<path> scans on launch.
            if let path = ProcessInfo.processInfo.environment["NEODISK_AUTOSCAN"],
               model.coordinator.phase == .idle {
                model.startScan(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)))
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
        if let target = model.coordinator.selectedTarget {
            let total = model.coordinator.snapshot?.aggregateStats.totalAllocatedSize
            if let total {
                return "\(target.displayName) (\(NeodiskFormatters.size(total)))"
            }
            return target.displayName
        }
        return "Neodisk"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $preferences.vizViewMode) {
                Label("Treemap", systemImage: "square.split.bottomrightquarter")
                    .tag(VizViewMode.treemap)
                Label("Sunburst", systemImage: "chart.pie")
                    .tag(VizViewMode.sunburst)
            }
            .pickerStyle(.segmented)
            .disabled(model.coordinator.snapshot == nil)
            .help("Switch between treemap and sunburst views")
        }

        ToolbarItemGroup {
            // Update status pill: sits between the center view picker and
            // the trailing buttons. Hidden while idle; once a check runs it
            // persists until the user acts on it (see UpdateIndicator).
            UpdateIndicator(viewModel: updates.viewModel)

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
}

// MARK: - Welcome

private struct WelcomeView: View {
    let model: NeodiskViewModel

    private var startupVolume: ScanTarget? {
        SystemIntegration.volumeTargets().first
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Choose a Folder or Disk")
                .font(.title.weight(.semibold))

            Text("Start from the sidebar, drop a folder into the window,\nor choose a location manually.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Choose Folder…") {
                    model.chooseFolderAndScan()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")

                if let startupVolume {
                    Button("Scan \(startupVolume.displayName)") {
                        model.startScan(startupVolume)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scanning

private struct ScanProgressView: View {
    let model: NeodiskViewModel

    var body: some View {
        ScanProgressContent(
            progress: model.coordinator.progress,
            targetName: model.coordinator.selectedTarget?.displayName ?? "",
            onStop: { model.stopScan() }
        )
    }
}

private struct ScanProgressContent: View {
    @ObservedObject var progress: ScanProgressState
    let targetName: String
    var onStop: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress.metrics.progressFraction)
                .frame(width: 340)

            Text(progress.metrics.progressFraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(progress.metrics.isFinalizing
                 ? "Assembling results for \(targetName)…"
                 : "Scanning \(targetName)…")
                .font(.headline)

            VStack(spacing: 4) {
                Text("\(progress.metrics.filesVisited.formatted()) files · \(NeodiskFormatters.size(progress.metrics.bytesDiscovered))")
                    .monospacedDigit()
                Text(progress.metrics.currentPath)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 420)
            }

            if let onStop {
                Button("Stop Scan", action: onStop)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Snapshot restore

/// Shown while a cached snapshot decodes with no scan running (large
/// locations skip the automatic rescan). Decode takes around a second per
/// million nodes, so this is a brief, quiet state.
private struct SnapshotRestoreView: View {
    let target: ScanTarget?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Opening last scan of \(target?.displayName ?? "location")…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Failed

private struct ScanFailedView: View {
    let model: NeodiskViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Scan failed")
                .font(.headline)
            if let message = model.coordinator.scanErrorMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            Button("Try Again") {
                if let target = model.coordinator.selectedTarget {
                    model.startScan(target)
                }
            }
            .disabled(model.coordinator.selectedTarget == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        guard let snapshot = model.coordinator.snapshot, snapshot.isComplete else { return 0 }
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
                .animation(.easeInOut(duration: 0.2), value: model.visibleScanWarnings.isEmpty)
                .animation(.easeInOut(duration: 0.2), value: model.snapshotNotice)
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
/// underreported until the app gets Full Disk Access.
private struct PermissionNoticeStrip: View {
    let count: Int

    /// Offering the Grant button when Full Disk Access is already on is a
    /// dead end (the remaining unreadable locations are protected for other
    /// reasons), so the strip probes the status and hides it — rechecking
    /// on app activation, i.e. when the user returns from System Settings.
    @State private var accessStatus: FullDiskAccessStatus = .unknown

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("\(count.formatted()) locations couldn't be read — sizes may be underreported.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if accessStatus != .granted {
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
        .task {
            await refreshAccessStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await refreshAccessStatus() }
        }
    }

    private func refreshAccessStatus() async {
        accessStatus = await Task.detached(priority: .utility) {
            SystemIntegration.fullDiskAccessStatus()
        }.value
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
            ProgressView(value: progress.metrics.progressFraction)
                .progressViewStyle(.linear)
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
            Text("\(progress.metrics.filesVisited.formatted()) files · \(NeodiskFormatters.size(progress.metrics.bytesDiscovered))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        if let cachedScanDate {
            let relative = DisplayFormatters.relativeDate(cachedScanDate)
            return String(format: NSLocalizedString("Last scanned %@ — refreshing…", comment: "Live strip, refreshing a cached scan"), relative)
        }
        return progress.metrics.isFinalizing
            ? NSLocalizedString("Finishing up…", comment: "Live strip, finalizing")
            : NSLocalizedString("Scanning…", comment: "Live strip, scanning")
    }
}

/// A draggable hairline divider between workspace panes. Implemented in
/// AppKit: `resetCursorRects` gives OS-managed resize-cursor behavior that
/// SwiftUI's onHover + NSCursor cannot match (the neighboring table views
/// keep resetting the cursor through their own cursor rects), and
/// `mouseDragged` deltas resize smoothly without coordinate-space fights.
private struct PaneSplitter: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the splitter the resizable pane sits on.
    let edge: HorizontalEdge

    func makeNSView(context: Context) -> SplitterNSView {
        let view = SplitterNSView()
        view.widthAnchor.constraint(equalToConstant: 8).isActive = true
        return view
    }

    func updateNSView(_ view: SplitterNSView, context: Context) {
        view.onDrag = { deltaX in
            let delta = edge == .leading ? deltaX : -deltaX
            width = min(max(width + delta, range.lowerBound), range.upperBound)
        }
    }
}

final class SplitterNSView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}

private struct StatusBar: View {
    let model: NeodiskViewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.hoveredCellIsFreeSpace {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(
                        red: Double(TreemapScene.freeSpaceRGB.x),
                        green: Double(TreemapScene.freeSpaceRGB.y),
                        blue: Double(TreemapScene.freeSpaceRGB.z)
                    ))
                    .frame(width: 10, height: 10)
                Text("Free space on this volume")
                Spacer(minLength: 12)
                if let freeSpaceBytes = model.freeSpaceBytes {
                    Text(NeodiskFormatters.size(freeSpaceBytes))
                        .monospacedDigit()
                }
            } else if model.hoveredCellIsHiddenSpace {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(
                        red: Double(TreemapScene.hiddenSpaceRGB.x),
                        green: Double(TreemapScene.hiddenSpaceRGB.y),
                        blue: Double(TreemapScene.hiddenSpaceRGB.z)
                    ))
                    .frame(width: 10, height: 10)
                Text("Hidden space on this volume")
                    .help("Purgeable space, local snapshots, and files the scan could not see.")
                Spacer(minLength: 12)
                if let hiddenSpaceBytes = model.hiddenSpaceBytes {
                    Text(NeodiskFormatters.size(hiddenSpaceBytes))
                        .monospacedDigit()
                }
            } else if let aggregate = model.hoveredAggregate, let folder = model.hoveredNode {
                RoundedRectangle(cornerRadius: 2)
                    .fill(FileKindCatalog.otherColor)
                    .frame(width: 10, height: 10)
                Text("\(aggregate.itemCount.formatted()) smaller items in \(folder.url.path)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(NeodiskFormatters.size(aggregate.totalSize))
                    .monospacedDigit()
            } else if let node = model.hoveredNode ?? model.selectedNode {
                RoundedRectangle(cornerRadius: 2)
                    .fill(model.displayColor(for: node))
                    .frame(width: 10, height: 10)
                Text(node.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(LocalizedStringKey(FileKindClassifier.kind(for: node, mode: model.kinds.displayMode).displayName))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(NeodiskFormatters.size(node.allocatedSize))
                    .monospacedDigit()
            } else {
                Text("Hover the treemap or select a row to inspect an item.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
