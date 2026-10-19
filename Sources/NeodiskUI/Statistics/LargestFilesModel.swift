// Largest tab: browsing uses a dedicated O(N) top-N scan, since the shared search index is far more than a
// top-500 list needs; a name filter needs every name, so it builds that index once on demand.

import Foundation
import Observation
import NeodiskKit
import NeodiskAppModel

@MainActor
@Observable
final class LargestFilesModel {
    /// Cap for browsing with no filter typed — past the top files, the
    /// answer is the filter, not scrolling.
    static let browseLimit = 500
    /// Rows while a scan streams partial trees: the list re-renders with each
    /// refresh, and 100 rows diff in a fifth of the main-thread time.
    static let partialBrowseLimit = 100

    private(set) var isLoading = false
    /// The listed files as records, not their tree: rows kept across a splice
    /// held the replaced tree in memory.
    private(set) var rows: [FileNodeRecord] = []
    var visibleIDs: [String] { rows.map(\.id) }
    private(set) var totalMatches = 0
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            scheduleFilter()
        }
    }

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let indexService: SearchIndexService
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let filterDebouncer = SearchDebouncer()
    /// Built lazily on the first name filter; empty while browsing.
    @ObservationIgnored private var entries: [FileSearchEntry] = []
    @ObservationIgnored private var loadedSnapshotID: UUID?
    /// Whether cloud-only bytes count toward the ranking — mirrors the
    /// toolbar toggle, passed in by the pane on every load.
    @ObservationIgnored private var includeCloudOnly = false
    /// When the browse list was last refreshed from a partial tree: while a
    /// scan streams, it refreshes at most every `partialRefreshInterval`.
    @ObservationIgnored private var lastPartialRefresh: ContinuousClock.Instant?
    static let partialRefreshInterval: Duration = .seconds(2)

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.indexService = indexService
    }

    /// Loading only from the pane keeps hidden tabs from walking the tree during scans.
    func loadIfNeeded(includeCloudOnly: Bool = false) {
        guard let snapshot = coordinator.snapshot else { return }
        guard loadedSnapshotID != snapshot.id || self.includeCloudOnly != includeCloudOnly else {
            return
        }
        // Re-ranking 500 rows per partial kept the main thread busy; the final tree and an empty list
        // always refresh.
        if !snapshot.isComplete, !rows.isEmpty, self.includeCloudOnly == includeCloudOnly,
           filterText.trimmingCharacters(in: .whitespaces).isEmpty,
           let lastPartialRefresh, lastPartialRefresh.duration(to: .now) < Self.partialRefreshInterval {
            return
        }
        lastPartialRefresh = snapshot.isComplete ? nil : .now
        let snapshotChanged = loadedSnapshotID != snapshot.id
        loadedSnapshotID = snapshot.id
        self.includeCloudOnly = includeCloudOnly
        if snapshotChanged {
            // A new tree: any lazily-built index entries belong to the old one.
            entries = []
        }
        // Keep the previous list on screen while a partial refresh rebuilds;
        // the spinner is for the nothing-yet case only.
        isLoading = rows.isEmpty
        applyFilter()
    }

    /// The filter text survives so streaming partials don't wipe typing. `keepingRows` avoids clearing per
    /// partial, which rebuilt the table twice each time and made the list blink.
    func snapshotDidChange(keepingRows: Bool = false) {
        loadTask?.cancel()
        filterDebouncer.cancel()
        entries = []
        loadedSnapshotID = nil
        isLoading = false
        guard !keepingRows else { return }
        lastPartialRefresh = nil
        rows = []
        totalMatches = 0
    }

    /// Unlike snapshotDidChange, the filter belongs to the previous location and goes too.
    func reset() {
        snapshotDidChange()
        filterText = ""
    }

    private func scheduleFilter() {
        filterDebouncer.cancel()
        // Building the index takes seconds on a large scan; the size-ranked browse list wouldn't reflect the query.
        if entries.isEmpty, !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            isLoading = true
        }
        applyFilter()
    }

    /// Re-reads filterText, so it's safe to call again after an await lands.
    private func applyFilter() {
        guard let snapshot = coordinator.snapshot else { return }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            loadBrowseList(snapshot: snapshot)
        } else {
            loadFilteredList(snapshot: snapshot, query: query)
        }
    }

    /// Never the shared index, so opening the tab and streaming partials don't force a full index build.
    private func loadBrowseList(snapshot: ScanSnapshot) {
        loadTask?.cancel()
        filterDebouncer.cancel()
        // A built index's prefix is the browse list, except with cloud-only weighting (it ranks by on-disk size).
        if !entries.isEmpty, !includeCloudOnly {
            isLoading = false
            rows = entries.prefix(Self.browseLimit).compactMap { snapshot.treeStore.node(id: $0.id) }
            totalMatches = entries.count
            return
        }
        let limit = snapshot.isComplete ? Self.browseLimit : Self.partialBrowseLimit
        let includeCloudOnly = includeCloudOnly
        loadTask = Task { [weak self] in
            let store = snapshot.treeStore
            let result = await Task.detached(priority: .userInitiated) {
                let result = TopLargestFiles.select(from: store, limit: limit, includeCloudOnly: includeCloudOnly)
                return (rows: result.ids.compactMap { store.node(id: $0) }, totalMatches: result.totalMatches)
            }.cancellableValue
            guard let self, !Task.isCancelled,
                  self.coordinator.snapshot?.id == snapshot.id,
                  self.filterText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.isLoading = false
            self.rows = result.rows
            self.totalMatches = result.totalMatches
        }
    }

    private func loadFilteredList(snapshot: ScanSnapshot, query: String) {
        guard entries.isEmpty else {
            applyFuzzy(query: query)
            return
        }
        loadTask?.cancel()
        filterDebouncer.cancel()
        loadTask = Task { [weak self, indexService] in
            let index = await indexService.index(for: snapshot)
            guard !Task.isCancelled else { return }
            let entries = await Task.detached(priority: .userInitiated) {
                index.entries.filter(\.isKindCountable)
            }.cancellableValue
            guard let self, !Task.isCancelled,
                  self.coordinator.snapshot?.id == snapshot.id else { return }
            self.entries = entries
            // The filter may have changed or cleared while the index built;
            // re-route rather than assuming the original query still holds.
            self.applyFilter()
        }
    }

    private func applyFuzzy(query: String) {
        let limit = Self.browseLimit
        let entries = entries
        let includeCloudOnly = includeCloudOnly
        let store = coordinator.snapshot?.treeStore
        filterDebouncer.schedule { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                // Order-preserving on purpose: this list ranks by size, and
                // the filter narrows that ranking.
                var results = FuzzyMatcher.matchesInEntryOrder(query: query, entries: entries, limit: limit)
                // The index ranks by on-disk size; re-rank by display weight (bounded by `limit`).
                if includeCloudOnly, let store {
                    results.ids.sort { lhs, rhs in
                        let lhsWeight = store.node(id: lhs)?.displayWeight(includingCloudOnly: true) ?? 0
                        let rhsWeight = store.node(id: rhs)?.displayWeight(includingCloudOnly: true) ?? 0
                        return lhsWeight != rhsWeight ? lhsWeight > rhsWeight : lhs < rhs
                    }
                }
                return (rows: results.ids.compactMap { store?.node(id: $0) }, totalMatches: results.totalMatches)
            }.cancellableValue
            guard let self, !Task.isCancelled,
                  self.filterText.trimmingCharacters(in: .whitespaces) == query else {
                return
            }
            self.isLoading = false
            self.rows = results.rows
            self.totalMatches = results.totalMatches
        }
    }
}

/// One O(N) pass keeping the top `limit` nodes in a bounded min-heap, so no full entry array or sort is
/// materialized. IDs come out allocated-size descending, matching the index order.
private enum TopLargestFiles {
    struct Result: Sendable {
        var ids: [String]
        var totalMatches: Int
    }

    static func select(from store: FileTreeStore, limit: Int, includeCloudOnly: Bool = false) -> Result {
        var total = 0
        // Parallel arrays as a binary min-heap of the kept entries: the root
        // is the smallest kept size, so it is the first evicted once full.
        var heapSizes: [Int64] = []
        var heapIDs: [String] = []
        heapSizes.reserveCapacity(limit)
        heapIDs.reserveCapacity(limit)

        for node in store.allNodes {
            if Task.isCancelled { break }
            guard FileKindClassifier.isKindCountable(node, in: store) else { continue }
            total += 1
            let size = node.displayWeight(includingCloudOnly: includeCloudOnly)
            if heapSizes.count < limit {
                heapSizes.append(size)
                heapIDs.append(node.id)
                siftUp(&heapSizes, &heapIDs, from: heapSizes.count - 1)
            } else if size > heapSizes[0] {
                heapSizes[0] = size
                heapIDs[0] = node.id
                siftDown(&heapSizes, &heapIDs, from: 0)
            }
        }

        // Present the kept entries largest first; ties break by ID so a
        // partial refresh doesn't reshuffle equal-sized rows.
        var order = Array(heapSizes.indices)
        order.sort { lhs, rhs in
            heapSizes[lhs] != heapSizes[rhs]
                ? heapSizes[lhs] > heapSizes[rhs]
                : heapIDs[lhs] < heapIDs[rhs]
        }
        return Result(ids: order.map { heapIDs[$0] }, totalMatches: total)
    }

    private static func siftUp(_ sizes: inout [Int64], _ ids: inout [String], from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard sizes[child] < sizes[parent] else { break }
            sizes.swapAt(child, parent)
            ids.swapAt(child, parent)
            child = parent
        }
    }

    private static func siftDown(_ sizes: inout [Int64], _ ids: inout [String], from index: Int) {
        let count = sizes.count
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < count, sizes[left] < sizes[smallest] { smallest = left }
            if right < count, sizes[right] < sizes[smallest] { smallest = right }
            guard smallest != parent else { break }
            sizes.swapAt(parent, smallest)
            ids.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
