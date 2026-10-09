//
//  LargestFilesModel.swift
//  Neodisk
//
//  The statistics panel's Largest tab: the whole scan's biggest files as a
//  flat, size-descending list ("what's eating my disk"), with the same
//  fuzzy filter as the drill-in lists. Owned by NeodiskViewModel as
//  `model.largest`. The unfiltered browse list comes from a dedicated O(N)
//  top-N scan that never touches the shared search index — that index is a
//  full classified, sorted array of every node, far more than a top-500
//  browse needs. Typing a name filter needs every name, so it falls back to
//  the shared index, built once on demand off the critical path.
//

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
    /// The listed files as records, not their tree: a hidden tab never refreshes,
    /// and holding the tree kept every replaced scan in memory.
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
    /// Every kind-countable entry of the loaded snapshot, allocated-size
    /// descending — the shared index filtered down. Built lazily only when a
    /// name filter is first used (the filter matches against all names, not
    /// just the visible prefix); empty while browsing.
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

    /// Called from the pane whenever it is on screen with a snapshot (tab
    /// switches, partial-snapshot updates, and cloud-only toggle flips);
    /// no-op when the list already matches the displayed snapshot and
    /// toggle. Loading only from the pane keeps hidden tabs from scanning
    /// the tree during scans.
    func loadIfNeeded(includeCloudOnly: Bool = false) {
        guard let snapshot = coordinator.snapshot else { return }
        guard loadedSnapshotID != snapshot.id || self.includeCloudOnly != includeCloudOnly else {
            return
        }
        // Partial trees arrive several times a second; re-ranking and
        // re-rendering 500 rows for each kept the main thread busy. The final
        // tree always refreshes, and so does a list that is still empty.
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

    /// The displayed tree changed: the list holds node IDs of the replaced
    /// tree. The filter text survives (like the outline search query) so a
    /// scan streaming partials doesn't wipe what the user is typing; the
    /// pane's task reloads against the new tree whenever it is visible.
    ///
    /// A newer tree of the same location (the next partial, or the scan's
    /// final tree) keeps the rows until the reload replaces them: clearing
    /// made every partial empty the list and refill 500 rows, a full table
    /// rebuild twice per partial on the main thread, and a blinking list.
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

    /// Full clear before a new scan takes the screen (part of the model's
    /// per-scan state reset) — unlike snapshotDidChange, the filter belongs
    /// to the previous location and goes too.
    func reset() {
        snapshotDidChange()
        filterText = ""
    }

    private func scheduleFilter() {
        filterDebouncer.cancel()
        // First use of a name filter must build the shared index (seconds on
        // a large scan); show the spinner rather than the browse list, which
        // ranks by size and would not reflect the query.
        if entries.isEmpty, !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            isLoading = true
        }
        applyFilter()
    }

    /// Routes to the browse list (no filter, no shared index) or the fuzzy
    /// filter (needs the index) for the current filter text. Re-reads
    /// filterText fresh so it is safe to call again after an await lands.
    private func applyFilter() {
        guard let snapshot = coordinator.snapshot else { return }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            loadBrowseList(snapshot: snapshot)
        } else {
            loadFilteredList(snapshot: snapshot, query: query)
        }
    }

    /// The unfiltered browse list: the biggest kind-countable files, largest
    /// first, from a dedicated O(N) top-N scan — never the shared index, so
    /// opening the tab and streaming partials don't force a full index build.
    private func loadBrowseList(snapshot: ScanSnapshot) {
        loadTask?.cancel()
        filterDebouncer.cancel()
        // Once the index has been built for a filter, its size-descending
        // prefix is exactly the browse list — reuse it instead of rescanning.
        // Not with cloud-only weighting: the index ranks by on-disk size, so
        // the top-N rescan (which ranks by display weight) stays the truth.
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

    /// The fuzzy filter path: matching names needs every name, so it lazily
    /// builds the shared index once (off the critical path — the browse list
    /// is already on screen) and fuzzy-matches over it. First use spins while
    /// the index builds; later keystrokes reuse the loaded entries behind the
    /// debounce.
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
                // The index order is on-disk size; with cloud-only weighting
                // on, re-rank the kept matches by display weight (bounded by
                // `limit`, so the store lookups stay cheap).
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

/// The unfiltered Largest browse list without the shared search index: a
/// single O(N) scan of the tree keeping only the top `limit` kind-countable
/// nodes by allocated size in a bounded min-heap (a node no bigger than the
/// smallest kept entry is rejected in one comparison), plus a running count
/// of every kind-countable node. No full entry array and no full sort are
/// materialized — only the `limit` kept entries are sorted at the end. The
/// returned IDs are allocated-size descending, matching the index-backed
/// browse order the filter path reuses.
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
