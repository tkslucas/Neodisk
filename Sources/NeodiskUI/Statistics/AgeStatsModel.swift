//
//  AgeStatsModel.swift
//  Neodisk
//

import Foundation
import Observation
import NeodiskKit

/// Modification-age statistics state: the bucket catalog (rebuilt lazily
/// when the Age pane is on screen, with the same adaptive throttle as the
/// kind catalog) and the drill-in file list for one bucket. Owned by
/// NeodiskViewModel as `model.ages` — the Age tab's counterpart to
/// KindStatsModel. Building only from the pane (via `loadIfNeeded`, like
/// LargestFilesModel) keeps a hidden Age tab from forcing the O(N) build
/// during a scan or snapshot restore.
@MainActor
@Observable
final class AgeStatsModel {
    private(set) var catalog: AgeCatalog = .empty

    /// The drill-in list for one bucket ("what did I touch this week"): every
    /// countable node modified in that period, largest first. Shares its
    /// engine with the Kind tab; the context is the bucket it is showing.
    let drill: StatsDrillInList<AgeBucket>

    /// Bucket lit up on the treemap while a drill-in list is open, mirroring
    /// KindStatsModel.highlightedKindID: derived from the open list, so it
    /// clears when the list closes (snapshot changes reset it).
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

    /// The displayed tree changed. Drops the drill-in list (its node IDs
    /// belong to the replaced tree) and the loaded-snapshot marker so the
    /// pane rebuilds when next visible; the catalog itself is rebuilt lazily
    /// by `loadIfNeeded`, not here — a hidden Age tab never pays the O(N)
    /// build. The catalog stays on screen across a live scan's partials (so
    /// the pane doesn't flash empty while the throttle skips a rebuild);
    /// only a nil snapshot — nothing displayed — clears it outright.
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

    /// Called from the Age pane whenever it is on screen with a snapshot (tab
    /// switches and partial-snapshot updates alike). Rebuilds the bucket
    /// totals for the displayed snapshot; no-op once the catalog matches it.
    /// While a scan streams partials the rebuild is throttled by the same
    /// adaptive interval as KindStatsModel, so a fast-changing tree doesn't
    /// rebuild the O(N) catalog on every partial; the final complete snapshot
    /// always rebuilds.
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
            }.value
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
