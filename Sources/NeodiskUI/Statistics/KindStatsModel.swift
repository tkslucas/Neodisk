//
//  KindStatsModel.swift
//  Neodisk
//
//  File-kind statistics state: the kind catalog (with its adaptive rebuild
//  throttle while partials stream in), the Categories/Types display mode,
//  and the searchable drill-in file list for one kind. Owned by
//  NeodiskViewModel as `model.kinds`.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class KindStatsModel {
    private(set) var catalog: FileKindCatalog = .empty
    /// Whether kind statistics (and treemap colors) group by extension or by
    /// broad category. Switching rebuilds the catalog.
    /// The active color palette (swapped by the colorblind Settings toggle).
    /// Colors are baked into the catalog at build time, so changing this
    /// drops the cache and rebuilds so the new colors take effect.
    var palette: VizPalette = .standard {
        didSet {
            guard palette != oldValue else { return }
            catalogCache = [:]
            if let store = coordinator.snapshot?.treeStore {
                rebuildCatalog(from: store)
            }
        }
    }

    var displayMode: FileKindDisplayMode = .categories {
        didSet {
            guard displayMode != oldValue,
                  let store = coordinator.snapshot?.treeStore else { return }
            // The drilled-in list belongs to the previous grouping.
            closeFileList()
            // Switching back to a mode already built for this snapshot is
            // instant; otherwise rebuild (the pane shows a spinner while the
            // catalog mode lags behind the selected mode).
            if let cached = catalogCache[displayMode] {
                catalog = cached
            } else {
                rebuildCatalog(from: store)
            }
        }
    }

    // MARK: Kind file list

    /// The subject of an open kind drill-in: the kind and the grouping mode it
    /// was opened under, so a highlight left over from a stale mode is
    /// dropped while a catalog rebuild is in flight.
    struct DrillContext: Sendable {
        let kind: FileKind
        let mode: FileKindDisplayMode
    }

    /// The drill-in list for one kind ("where are all my videos"): every
    /// countable node of that kind, largest first. Read-only navigation —
    /// clicking a row selects the node in the outline and treemap. Shares its
    /// engine with the Age tab.
    let drill: StatsDrillInList<DrillContext>

    /// Kind lit up on the treemap while a drill-in list is open: matching
    /// cells keep their color, everything else dims. Derived from the open
    /// list, so it clears when the list closes (mode switches, snapshot
    /// changes). The mode guard drops a stale highlight while a catalog
    /// rebuild is in flight.
    var highlightedKindID: String? {
        guard let context = drill.context, context.mode == catalog.mode else { return nil }
        return context.kind.id
    }

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private var catalogCache: [FileKindDisplayMode: FileKindCatalog] = [:]
    @ObservationIgnored private var catalogBuildTask: Task<Void, Never>?
    /// Persisted stats loaded ahead of a snapshot restore, waiting for the
    /// decoded snapshot to arrive and prove they describe it.
    @ObservationIgnored private var pendingSeed: KindStatsSidecar?
    /// Persisted stats proven to match the displayed snapshot: catalog
    /// rebuilds (grouping mode, palette) skip the O(nodes) pass while set.
    @ObservationIgnored private var activeSeed: KindStatsSidecar?
    /// Rebuild throttle while partials stream in — the same adaptive interval
    /// as the age catalog.
    @ObservationIgnored private var rebuildThrottle = CatalogRebuildThrottle()

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.drill = StatsDrillInList(indexService: indexService)
    }

    /// Clears the displayed catalog before a new scan or snapshot takes the
    /// screen (part of the model's per-scan state reset). Seeds go too —
    /// callers restoring a snapshot hand fresh ones over after the reset.
    func reset() {
        catalog = .empty
        pendingSeed = nil
        activeSeed = nil
    }

    /// Hands over persisted stats loaded ahead of a snapshot restore. They
    /// stay pending until a complete snapshot arrives: a match seeds the
    /// catalog rebuilds, a mismatch discards them.
    func prepareSeed(_ sidecar: KindStatsSidecar?) {
        pendingSeed = sidecar
    }

    /// The displayed tree changed: drop caches keyed to the old tree, then
    /// rebuild the catalog — throttled while partial snapshots stream in
    /// (rebuilding is O(nodes)); the final snapshot always rebuilds.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        // The tree changed; cached catalogs are stale either way.
        catalogCache = [:]

        // The drilled-in kind list holds node IDs of the replaced tree.
        closeFileList()

        guard let snapshot else {
            catalogBuildTask?.cancel()
            catalog = .empty
            rebuildThrottle.reset()
            return
        }

        // A complete snapshot settles the seeds: pending stats either prove
        // they describe this snapshot or die here, and stats matched to a
        // previous tree (splices change the node count) stop being used.
        if snapshot.isComplete {
            if let pendingSeed, pendingSeed.matches(snapshot) {
                activeSeed = pendingSeed
            } else if let activeSeed, !activeSeed.matches(snapshot) {
                self.activeSeed = nil
            }
            pendingSeed = nil
        } else {
            activeSeed = nil
        }

        if !snapshot.isComplete, rebuildThrottle.shouldSkip() { return }
        rebuildThrottle.noteBuildStarted()
        rebuildCatalog(from: snapshot.treeStore)
    }

    private func rebuildCatalog(from store: FileTreeStore) {
        catalogBuildTask?.cancel()
        let mode = displayMode
        let palette = palette
        let seedStats = activeSeed?.stats(for: mode)
        catalogBuildTask = Task { [weak self] in
            let buildStart = ContinuousClock.now
            let catalog = await Task.detached(priority: .userInitiated) {
                if let seedStats {
                    return FileKindCatalog.build(fromAggregated: seedStats, mode: mode, palette: palette)
                }
                return FileKindCatalog.build(from: store, mode: mode, palette: palette)
            }.value
            let buildDuration = ContinuousClock.now - buildStart
            guard !Task.isCancelled, let self else { return }
            self.rebuildThrottle.noteBuildDuration(buildDuration)
            self.catalog = catalog
            self.catalogCache[mode] = catalog
        }
    }

    // MARK: - Drill-in file list

    /// Opens the drill-in list for a kind row ("where are all my videos").
    /// The list is a filter over the shared per-snapshot search index,
    /// whose size-descending order is exactly the browse order.
    func openFileList(for stat: FileKindStat) {
        guard let snapshot = coordinator.snapshot else { return }
        let mode = displayMode
        let kind = stat.kind
        drill.open(context: DrillContext(kind: kind, mode: mode), snapshot: snapshot) { entry in
            entry.isKindCountable && entry.kindID(for: mode) == kind.id
        }
    }

    func closeFileList() {
        drill.close()
    }
}
