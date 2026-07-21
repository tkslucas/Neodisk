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

enum DevLaunchHooks {
    @MainActor
    static func apply(model: NeodiskViewModel, updates: UpdateController) {
        let environment = ProcessInfo.processInfo.environment

        // NEODISK_AUTOSCAN=<path> scans on launch. A connected cloud account's
        // target ID (cloudscan://…) works too, composing with
        // NEODISK_CLOUD_FIXTURE for headless cloud runs.
        if let path = environment["NEODISK_AUTOSCAN"], model.coordinator.phase == .idle {
            if let cloudTarget = model.cloudAccounts.accounts.first(where: { $0.id == path }) {
                model.startScan(cloudTarget)
            } else {
                model.startScan(ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory)))
            }
            // NEODISK_BENCH_RESCANS drives repeated in-app rescans of the
            // just-started scan to measure felt rescan cost with the baseline
            // in memory (no relaunch/decode).
            BenchRescanDriver.shared.startIfRequested(model: model)
        }

        // NEODISK_ANALYSIS_TAB=<kinds|largest|age|duplicates|changes> opens
        // that statistics tab, so headless snapshots can capture any tab.
        if let rawTab = environment["NEODISK_ANALYSIS_TAB"], let tab = AnalysisTab(rawValue: rawTab) {
            model.analysisTab = tab
        }

        // NEODISK_VIZ_MODE=<treemap|sunburst> picks the center visualization
        // without persisting a preference.
        if let rawMode = environment["NEODISK_VIZ_MODE"], let mode = VizViewMode(rawValue: rawMode) {
            model.vizViewMode = mode
        }

        // NEODISK_TREEMAP_STYLE=<cushion|flat> picks the treemap style without
        // persisting the preference.
        if let rawStyle = environment["NEODISK_TREEMAP_STYLE"], let style = TreemapStyle(rawValue: rawStyle) {
            model.treemapStyle = style
        }

        // NEODISK_OUTLINE_POSITION=<leading|bottom> docks the file list
        // without persisting the preference.
        if let rawPosition = environment["NEODISK_OUTLINE_POSITION"],
           let position = OutlinePosition(rawValue: rawPosition) {
            model.devOutlinePositionOverride = position
            model.outlinePosition = position
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
    }

    /// Walks the scanned tree down to the node whose path matches, for the
    /// NEODISK_AUTOREVEAL dev hook.
    @MainActor
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
}
