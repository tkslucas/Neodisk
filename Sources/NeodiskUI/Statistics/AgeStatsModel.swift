import Foundation
import Observation
import NeodiskKit
import NeodiskAppModel

/// Age tab state: the bucket catalog and one bucket's drill-in list. Built only from the pane
/// (`loadIfNeeded`), so a hidden Age tab never forces the O(N) build mid-scan.
@MainActor
@Observable
final class AgeStatsModel {
    private(set) var catalog: AgeCatalog = .empty

    /// Every countable node modified in that bucket's period, largest first.
    let drill: StatsDrillInList<AgeBucket>

    /// Derived from the open list, so it clears when the list closes.
    var highlightedBucket: AgeBucket? { drill.context }

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private var catalogBuildTask: Task<Void, Never>?
    /// The snapshot the catalog was last built (or is being built) for, so
    /// `loadIfNeeded` is a no-op once the catalog matches what's on screen.
    @ObservationIgnored private var loadedSnapshotID: UUID?
    /// Same rebuild throttle as KindStatsModel while partials stream in.
    @ObservationIgnored private var rebuildThrottle = CatalogRebuildThrottle()

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.drill = StatsDrillInList(indexService: indexService)
    }

    /// Clears the displayed catalog before a new scan or snapshot takes the
    /// screen (part of the model's per-scan state reset).
    func reset() {
        catalogBuildTask?.cancel()
        catalog = .empty
        loadedSnapshotID = nil
        rebuildThrottle.reset()
    }

    /// Drops the drill-in list (its IDs belong to the old tree). The catalog stays across partials so the pane
    /// doesn't flash empty; only a nil snapshot clears it.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        // The drilled-in bucket list holds node IDs of the replaced tree.
        drill.close()
        catalogBuildTask?.cancel()
        loadedSnapshotID = nil
        if snapshot == nil {
            catalog = .empty
            rebuildThrottle.reset()
        }
    }

    /// During a scan, rebuilds are throttled like KindStatsModel so partials don't each pay O(N); the final
    /// snapshot always rebuilds.
    func loadIfNeeded() {
        guard let snapshot = coordinator.snapshot else { return }
        guard loadedSnapshotID != snapshot.id else { return }

        if !snapshot.isComplete, rebuildThrottle.shouldSkip() { return }
        loadedSnapshotID = snapshot.id
        rebuildThrottle.noteBuildStarted()
        rebuildCatalog(from: snapshot)
    }

    private func rebuildCatalog(from snapshot: ScanSnapshot) {
        catalogBuildTask?.cancel()
        let store = snapshot.treeStore
        let referenceDate = snapshot.finishedAt ?? snapshot.startedAt
        catalogBuildTask = Task { [weak self] in
            let buildStart = ContinuousClock.now
            let catalog = await Task.detached(priority: .userInitiated) {
                AgeCatalog.build(from: store, referenceDate: referenceDate)
            }.cancellableValue
            let buildDuration = ContinuousClock.now - buildStart
            guard !Task.isCancelled, let self else { return }
            self.rebuildThrottle.noteBuildDuration(buildDuration)
            self.catalog = catalog
        }
    }

    /// Opens the drill-in list for a bucket row ("what did I touch this
    /// week"), a filter over the shared per-snapshot search index.
    func openFileList(for stat: AgeStat) {
        guard let snapshot = coordinator.snapshot else { return }
        let bucket = stat.bucket
        let referenceDate = catalog.referenceDate
        drill.open(context: bucket, snapshot: snapshot) { entry in
            entry.isKindCountable
                && AgeBucket.bucket(for: entry.lastModified, reference: referenceDate) == bucket
        }
    }

    func closeFileList() {
        drill.close()
    }
}
