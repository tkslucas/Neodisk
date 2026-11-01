//
//  DevLaunchHooks.swift
//  Neodisk
//
//  Dev/testing launch hooks read from NEODISK_* environment variables when
//  the window first appears: scan on launch, force a statistics tab / center
//  view / treemap style / update-pill state, and auto-reveal a node. All are
//  inert unless the matching variable is set — see AGENTS.md "Dev hooks".
//  Kept out of ContentView so the root view stays about composition.
//

import Foundation
import NeodiskKit
import TreemapKit
import NeodiskAppModel

enum DevLaunchHooks {
    @MainActor
    static func apply(model: NeodiskViewModel, updates: UpdateController) {
        let environment = ProcessInfo.processInfo.environment

        // NEODISK_AUTOSCAN=<path> scans on launch.
        if let path = environment["NEODISK_AUTOSCAN"], model.coordinator.phase == .idle {
            let target = ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
            #if DEBUG
            // Without access, scan as a click would once the index is in: a first scan offers Full Disk Access.
            if environment["NEODISK_FULL_DISK_ACCESS"] == "off" {
                model.warnings.fullDiskAccessStatus = .notGranted
                Task { @MainActor in
                    while !model.session.hasIndexedSnapshotCache { try? await Task.sleep(for: .milliseconds(50)) }
                    model.startChosenScan(target)
                }
            } else {
                model.startScan(target)
            }
            #else
            model.startScan(target)
            #endif
            // NEODISK_BENCH_RESCANS drives repeated in-app rescans of the
            // just-started scan to measure felt rescan cost with the baseline
            // in memory (no relaunch/decode).
            BenchRescanDriver.shared.startIfRequested(model: model)
            BenchActionDriver.startIfRequested(model: model)
        }

        // NEODISK_OPEN_CACHED=<path> shows that location's cached snapshot (NEODISK_SNAPSHOT_DIR) and never scans:
        // profiling on a big real tree without touching the disk.
        if let path = environment["NEODISK_OPEN_CACHED"], model.coordinator.phase == .idle {
            MainThreadMonitor.startIfProfiling()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let target = ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
                model.coordinator.beginSnapshotRestore(target)
                let started = ScanProfile.now()
                // Its own cache instance (same NEODISK_SNAPSHOT_DIR): a miss logs and stops, never scans.
                guard let cached = await ScanSnapshotCache().loadSnapshot(for: target) else {
                    ScanTiming.note("openCached: no snapshot for \(target.id)")
                    return
                }
                let nodes = cached.treeStore.nodeCount
                ScanTiming.note("openCached decoded ms=\((ScanProfile.now() &- started) / 1_000_000) nodes=\(nodes)")
                model.coordinator.completeSnapshotRestore(cached)
            }
            BenchActionDriver.startIfRequested(model: model)
        }

        // NEODISK_ANALYSIS_TAB=<kinds|largest|age|duplicates|changes> opens
        // that statistics tab, so headless snapshots can capture any tab.
        if let rawTab = environment["NEODISK_ANALYSIS_TAB"], let tab = AnalysisTab(rawValue: rawTab) {
            model.analysisTab = tab
        }

        // NEODISK_SIDEBAR_COLLAPSED=<volumes,cloudFiles,folders,cleanup> collapses those sidebar sections (the
        // rest expanded) for this run.
        if let raw = environment["NEODISK_SIDEBAR_COLLAPSED"] {
            let collapsed = Set(raw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) })
            model.devSidebarSectionsOverride = { sections in
                for section in SidebarSection.allCases {
                    sections.setExpanded(section, !collapsed.contains(section))
                }
            }
            model.syncSidebarSections()
        }

        // NEODISK_VIZ_MODE=<treemap|sunburst>, NEODISK_TREEMAP_STYLE=<cushion|flat> and
        // NEODISK_OUTLINE_POSITION=<leading|bottom> force that view or file list for this run, hidden or not.
        let mode = environment["NEODISK_VIZ_MODE"].flatMap(VizViewMode.init(rawValue:))
        let style = environment["NEODISK_TREEMAP_STYLE"].flatMap(TreemapStyle.init(rawValue:))
        let position = environment["NEODISK_OUTLINE_POSITION"].flatMap(OutlinePosition.init(rawValue:))
        if mode != nil || style != nil || position != nil {
            model.devLayoutOverride = { layout in
                if let style { layout.treemapStyle = style }
                if let mode { layout.mode = mode }
                layout.pick(layout.view)
                if let position {
                    layout.listPosition = position
                    layout.showsListWithTreemap = true
                }
            }
            model.syncWorkspaceLayout()
        }

        // NEODISK_SNAPSHOT_TEXT_SCALE=<0.85…2> scales the workspace text for this run without persisting it, so
        // window captures check text scaling as the pane snapshots do.
        if let scale = environment["NEODISK_SNAPSHOT_TEXT_SCALE"].flatMap(Double.init).map(TextScale.snapped) {
            model.textScale = scale
            OutlineRowMetrics.scale = CGFloat(scale)
        }

        // NEODISK_UPDATE_STATE=<checking|available|downloading|readyToInstall|
        // upToDate|failed> forces the update pill into a non-idle state at
        // launch (with inert closures), so headless snapshots can capture the
        // toolbar indicator without a live Sparkle check.
        if let rawUpdate = environment["NEODISK_UPDATE_STATE"], let forced = UpdateState.devState(named: rawUpdate) {
            updates.viewModel.state = forced
        }

        // NEODISK_AUTOREVEAL=<path> selects that node once it is scanned,
        // expanding its ancestors in the outline — lets headless snapshots
        // exercise deep trees and the external-selection reveal path.
        if let revealPath = environment["NEODISK_AUTOREVEAL"] {
            Task { @MainActor in
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let node = findNode(at: revealPath, in: model) {
                        model.select(node.id)
                        break
                    }
                }
            }
        }

        // NEODISK_AUTODRILL=<path> roots the map at that folder once the scan finishes, as a drill would: headless
        // snapshots show the drilled path bar, center and legend.
        if let drillPath = environment["NEODISK_AUTODRILL"] {
            Task { @MainActor in
                for _ in 0..<120 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !model.coordinator.isScanning, model.coordinator.snapshot?.isComplete == true else {
                        continue
                    }
                    if let node = findNode(at: drillPath, in: model) { _ = model.drillIn(to: node.id) }
                    break
                }
            }
        }

        // NEODISK_AUTOSELECT=<path>[:<path>...] selects those items once the scan finishes, the last one primary,
        // as ⌘-clicks would: headless snapshots show a multi-selection in every view.
        if let rawPaths = environment["NEODISK_AUTOSELECT"] {
            let paths = rawPaths.split(separator: ":").map(String.init)
            Task { @MainActor in
                for _ in 0..<120 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !model.coordinator.isScanning, model.coordinator.snapshot?.isComplete == true else {
                        continue
                    }
                    let ids = paths.compactMap { findNode(at: $0, in: model)?.id }
                    model.selection.replace(with: ids, primary: ids.last)
                    for id in ids { model.revealInOutline(id) }
                    FileHandle.standardError.write(Data(
                        "NEODISK_AUTOSELECT: selected \(ids.count) of \(paths.count)\n".utf8
                    ))
                    break
                }
            }
        }

        // NEODISK_AUTOCOLLECT=<path>[:<path>...] adds those items to Cleanup once the scan finishes, so a
        // headless snapshot shows the marks. Nothing moves: only the pile changes.
        if let rawPaths = environment["NEODISK_AUTOCOLLECT"] {
            let paths = rawPaths.split(separator: ":").map(String.init)
            Task { @MainActor in
                for _ in 0..<120 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !model.coordinator.isScanning, model.coordinator.snapshot?.isComplete == true else {
                        continue
                    }
                    let nodes = paths.compactMap { findNode(at: $0, in: model) }
                    model.cleanup.add(nodes)
                    FileHandle.standardError.write(Data(
                        "NEODISK_AUTOCOLLECT: found \(nodes.count) of \(paths.count), collected \(model.cleanup.itemIDs.count)\n".utf8
                    ))
                    // NEODISK_AUTOTRASH=1 then moves the pile as if confirmed: every safety check still runs.
                    // =fail fails every move and =hold holds them for a minute first; neither moves anything.
                    switch environment["NEODISK_AUTOTRASH"] {
                    case "1":
                        await autoTrash(model: model)
                    case "fail":
                        model.cleanup.trashItem = { _ in throw CocoaError(.fileWriteNoPermission) }
                        await autoTrash(model: model)
                    case "hold":
                        model.cleanup.trashItem = { _ in
                            Thread.sleep(forTimeInterval: 60)
                            throw CocoaError(.fileWriteNoPermission)
                        }
                        model.cleanup.confirm = { _ in true }
                        model.cleanup.moveAllToTrash()
                    default:
                        break
                    }
                    break
                }
            }
        }

        PaneSnapshotter.scheduleIfRequested(model: model)
    }

    @MainActor
    private static func autoTrash(model: NeodiskViewModel) async {
        let before = model.coordinator.snapshot?.root.allocatedSize ?? 0
        let earlierNotice = model.cleanup.notice?.id
        model.cleanup.confirm = { _ in true }
        model.cleanup.moveAllToTrash()
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(250))
            if !model.cleanup.isMoving, let notice = model.cleanup.notice, notice.id != earlierNotice { break }
        }
        let after = model.coordinator.snapshot?.root.allocatedSize ?? 0
        FileHandle.standardError.write(Data((
            "NEODISK_AUTOTRASH: \(model.cleanup.notice?.text ?? "no result"); root \(before) -> \(after); "
            + "left in Cleanup \(model.cleanup.itemIDs.count)\n"
        ).utf8))
    }

    /// Walks the scanned tree down to the node whose path matches, for the
    /// NEODISK_AUTOREVEAL dev hook.
    @MainActor
    static func findNode(at path: String, in model: NeodiskViewModel) -> FileNodeRecord? {
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
}
