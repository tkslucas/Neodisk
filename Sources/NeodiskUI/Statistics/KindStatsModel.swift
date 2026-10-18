// File-kind statistics: the kind catalog, its display mode and the drill-in list for one kind.

import Foundation
import Observation
import NeodiskKit
import NeodiskAppModel

@MainActor
@Observable
final class KindStatsModel {
    private(set) var catalog: FileKindCatalog = .empty
    /// Colors are baked into the catalog at build time, so changing this drops the cache and rebuilds.
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
            // A mode already built for this snapshot is instant.
            if let cached = catalogCache[displayMode] {
                catalog = cached
            } else {
                rebuildCatalog(from: store)
            }
        }
    }

    // MARK: Kind file list

    /// Carries the mode so a highlight from a stale mode drops while a rebuild is in flight.
    struct DrillContext: Sendable {
        let kind: FileKind
        let mode: FileKindDisplayMode
    }

    /// Every countable node of one kind, largest first. Shares its engine with the Age tab.
    let drill: StatsDrillInList<DrillContext>

    /// Matching cells keep their color, the rest dim; the mode guard drops a stale one mid-rebuild.
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

    /// Seeds go too; callers restoring a snapshot hand fresh ones over after the reset.
    func reset() {
        catalog = .empty
        pendingSeed = nil
        activeSeed = nil
    }

    /// Pending until a complete snapshot arrives: a match seeds the rebuilds, a mismatch discards them.
    func prepareSeed(_ sidecar: KindStatsSidecar?) {
        pendingSeed = sidecar
    }

    /// Rebuilding is O(nodes), so it's throttled while partials stream; the final snapshot always rebuilds.
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

        // Stats matched to a previous tree stop being used: splices change the node count.
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
            }.cancellableValue
            let buildDuration = ContinuousClock.now - buildStart
            guard !Task.isCancelled, let self else { return }
            self.rebuildThrottle.noteBuildDuration(buildDuration)
            self.catalog = catalog
            self.catalogCache[mode] = catalog
        }
    }

    /// The category rules changed: categories built under the old ones,
    /// and persisted stats aggregated under them, no longer hold.
    func categoryRulesDidChange() {
        catalogCache[.categories] = nil
        activeSeed = nil
        pendingSeed = nil
        if drill.context?.mode == .categories {
            closeFileList()
        }
        if displayMode == .categories, let store = coordinator.snapshot?.treeStore {
            rebuildCatalog(from: store)
        }
    }

    // MARK: - Drill-in file list

    /// A filter over the shared search index, whose size-descending order is the browse order.
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
