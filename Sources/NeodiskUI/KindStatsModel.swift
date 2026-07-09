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
    /// Cap for browsing a kind with no filter typed — SwiftUI's List
    /// degrades with hundreds of thousands of rows; the tail is reachable
    /// via search.
    static let fileBrowseLimit = 3_000

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

    /// A kind the user drilled into from the stats pane: every countable
    /// node of that kind, largest first. Read-only navigation — clicking a
    /// row selects the node in the outline and treemap.
    struct FileList: Sendable {
        let kind: FileKind
        let mode: FileKindDisplayMode
        /// Sorted by allocated size descending.
        let entries: [FileSearchEntry]
    }

    private(set) var fileList: FileList?
    /// Kind lit up on the treemap while a drill-in list is open: matching
    /// cells keep their color, everything else dims. Derived, so it clears
    /// with closeFileList (mode switches, snapshot changes). The mode
    /// guard drops a stale highlight while a catalog rebuild is in flight.
    var highlightedKindID: String? {
        guard let list = fileList, list.mode == catalog.mode else { return nil }
        return list.kind.id
    }
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
    @ObservationIgnored private var catalogCache: [FileKindDisplayMode: FileKindCatalog] = [:]
    @ObservationIgnored private var catalogBuildTask: Task<Void, Never>?
    @ObservationIgnored private var lastCatalogBuildTime: ContinuousClock.Instant?
    /// Rebuild throttle while partials stream in: at least the base
    /// interval, and never more than ~10% of the time spent building —
    /// the same cost × N adaptation as partial-tree emission.
    @ObservationIgnored private var catalogRebuildInterval: Duration = KindStatsModel.catalogRebuildBaseInterval
    private static let catalogRebuildBaseInterval: Duration = .seconds(1.5)

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.indexService = indexService
    }

    /// Clears the displayed catalog before a new scan or snapshot takes the
    /// screen (part of the model's per-scan state reset).
    func reset() {
        catalog = .empty
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
            lastCatalogBuildTime = nil
            return
        }

        if !snapshot.isComplete,
           let lastCatalogBuildTime,
           ContinuousClock.now - lastCatalogBuildTime < catalogRebuildInterval {
            return
        }
        lastCatalogBuildTime = ContinuousClock.now
        rebuildCatalog(from: snapshot.treeStore)
    }

    private func rebuildCatalog(from store: FileTreeStore) {
        catalogBuildTask?.cancel()
        let mode = displayMode
        let palette = palette
        catalogBuildTask = Task { [weak self] in
            let buildStart = ContinuousClock.now
            let catalog = await Task.detached(priority: .userInitiated) {
                FileKindCatalog.build(from: store, mode: mode, palette: palette)
            }.value
            let buildDuration = ContinuousClock.now - buildStart
            guard !Task.isCancelled, let self else { return }
            self.catalogRebuildInterval = max(Self.catalogRebuildBaseInterval, buildDuration * 10)
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
        fileListFilterText = ""
        isFileListLoading = true
        fileListBuildTask?.cancel()
        fileListBuildTask = Task { [weak self, indexService] in
            let index = await indexService.index(for: snapshot)
            let entries = await Task.detached(priority: .userInitiated) {
                index.entries.filter { $0.isKindCountable && $0.kindID(for: mode) == kind.id }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isFileListLoading = false
            self.fileList = FileList(kind: kind, mode: mode, entries: entries)
            self.fileListVisibleIDs = entries.prefix(Self.fileBrowseLimit).map(\.id)
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
            fileListVisibleIDs = list.entries.prefix(Self.fileBrowseLimit).map(\.id)
            fileListTotalMatches = list.entries.count
            return
        }
        let limit = Self.fileBrowseLimit
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
