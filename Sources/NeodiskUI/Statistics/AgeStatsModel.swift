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

    // MARK: Bucket file list

    /// A bucket the user drilled into from the Age tab: every countable
    /// node modified in that period, largest first.
    struct FileList: Sendable {
        let bucket: AgeBucket
        /// Sorted by allocated size descending.
        let entries: [FileSearchEntry]
    }

    private(set) var fileList: FileList?
    /// Bucket lit up on the treemap while a drill-in list is open, mirroring
    /// KindStatsModel.highlightedKindID: derived, so it clears with
    /// closeFileList (snapshot changes reset it).
    var highlightedBucket: AgeBucket? { fileList?.bucket }
    private(set) var isFileListLoading = false
    private(set) var fileListVisibleIDs: [String] = []
    private(set) var fileListTotalMatches = 0
    var fileListFilterText = "" {
        didSet {
            guard fileListFilterText != oldValue else { return }
            scheduleFileListFilter()
        }
    }

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let indexService: SearchIndexService
    @ObservationIgnored private var fileListBuildTask: Task<Void, Never>?
    @ObservationIgnored private let fileListFilterDebouncer = SearchDebouncer()
    @ObservationIgnored private var catalogBuildTask: Task<Void, Never>?
    /// The snapshot the catalog was last built (or is being built) for, so
    /// `loadIfNeeded` is a no-op once the catalog matches what's on screen.
    @ObservationIgnored private var loadedSnapshotID: UUID?
    @ObservationIgnored private var lastCatalogBuildTime: ContinuousClock.Instant?
    /// Same rebuild throttle as KindStatsModel while partials stream in.
    @ObservationIgnored private var catalogRebuildInterval: Duration = AgeStatsModel.catalogRebuildBaseInterval
    private static let catalogRebuildBaseInterval: Duration = .seconds(1.5)

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.indexService = indexService
    }

    /// Clears the displayed catalog before a new scan or snapshot takes the
    /// screen (part of the model's per-scan state reset).
    func reset() {
        catalogBuildTask?.cancel()
        catalog = .empty
        loadedSnapshotID = nil
        lastCatalogBuildTime = nil
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
        closeFileList()
        catalogBuildTask?.cancel()
        loadedSnapshotID = nil
        if snapshot == nil {
            catalog = .empty
            lastCatalogBuildTime = nil
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

        if !snapshot.isComplete,
           let lastCatalogBuildTime,
           ContinuousClock.now - lastCatalogBuildTime < catalogRebuildInterval {
            return
        }
        loadedSnapshotID = snapshot.id
        lastCatalogBuildTime = ContinuousClock.now
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
            self.catalogRebuildInterval = max(Self.catalogRebuildBaseInterval, buildDuration * 10)
            self.catalog = catalog
        }
    }

    // MARK: - Drill-in file list

    /// Opens the drill-in list for a bucket row ("what did I touch this
    /// week"), a filter over the shared per-snapshot search index.
    func openFileList(for stat: AgeStat) {
        guard let snapshot = coordinator.snapshot else { return }
        let bucket = stat.bucket
        let referenceDate = catalog.referenceDate
        fileListFilterText = ""
        isFileListLoading = true
        fileListBuildTask?.cancel()
        fileListBuildTask = Task { [weak self, indexService] in
            let index = await indexService.index(for: snapshot)
            let entries = await Task.detached(priority: .userInitiated) {
                index.entries.filter {
                    $0.isKindCountable
                        && AgeBucket.bucket(for: $0.lastModified, reference: referenceDate) == bucket
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isFileListLoading = false
            self.fileList = FileList(bucket: bucket, entries: entries)
            self.fileListVisibleIDs = entries.prefix(KindStatsModel.fileBrowseLimit).map(\.id)
            self.fileListTotalMatches = entries.count
        }
    }

    func closeFileList() {
        fileListBuildTask?.cancel()
        fileListFilterDebouncer.cancel()
        fileList = nil
        isFileListLoading = false
        fileListFilterText = ""
        fileListVisibleIDs = []
        fileListTotalMatches = 0
    }

    private func scheduleFileListFilter() {
        fileListFilterDebouncer.cancel()
        guard let list = fileList else { return }
        let query = fileListFilterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            fileListVisibleIDs = list.entries.prefix(KindStatsModel.fileBrowseLimit).map(\.id)
            fileListTotalMatches = list.entries.count
            return
        }
        let limit = KindStatsModel.fileBrowseLimit
        fileListFilterDebouncer.schedule { [weak self] in
            let entries = list.entries
            let results = await Task.detached(priority: .userInitiated) {
                // Order-preserving on purpose: this list ranks by size, and
                // the filter narrows that ranking.
                FuzzyMatcher.matchesInEntryOrder(query: query, entries: entries, limit: limit)
            }.value
            guard let self, !Task.isCancelled,
                  self.fileListFilterText.trimmingCharacters(in: .whitespaces) == query else {
                return
            }
            self.fileListVisibleIDs = results.ids
            self.fileListTotalMatches = results.totalMatches
        }
    }
}
