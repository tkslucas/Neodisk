//
//  StatsDrillInList.swift
//  Neodisk
//
//  The drill-in file list shared by the Kind and Age stats tabs: a
//  size-descending slice of the shared per-snapshot search index for one
//  subject (a file kind, or a modification-age bucket), with a debounced
//  fuzzy filter over it. The two tabs differ only in the subject they carry
//  (`Context`) and the predicate that selects its files.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class StatsDrillInList<Context: Sendable> {
    /// Cap for browsing with no filter typed — SwiftUI's List degrades with
    /// hundreds of thousands of rows; the tail is reachable via search.
    static var browseLimit: Int { 3_000 }

    /// The open list's subject, set once its files have finished loading —
    /// nil while loading or closed, mirroring the old `fileList` marker so a
    /// derived treemap highlight only lights up on a fully built list.
    private(set) var context: Context?
    private(set) var isLoading = false
    private(set) var visibleIDs: [String] = []
    private(set) var totalMatches = 0
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            scheduleFilter()
        }
    }

    /// True from `open` until `close`: the pane shows the drill-in view (a
    /// loading spinner until `context` lands) instead of the legend.
    private(set) var isActive = false

    @ObservationIgnored private var entries: [FileSearchEntry] = []
    @ObservationIgnored private let indexService: SearchIndexService
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private let filterDebouncer = SearchDebouncer()

    init(indexService: SearchIndexService) {
        self.indexService = indexService
    }

    /// Opens a drill-in list: filters the snapshot's search index (already
    /// size-descending, so the filter narrows that ranking) with `matches`,
    /// off the main actor. `context` is published only once the list lands.
    func open(
        context: Context,
        snapshot: ScanSnapshot,
        matches: @escaping @Sendable (FileSearchEntry) -> Bool
    ) {
        isActive = true
        self.context = nil
        filterText = ""
        isLoading = true
        buildTask?.cancel()
        buildTask = Task { [weak self, indexService] in
            let index = await indexService.index(for: snapshot)
            let entries = await Task.detached(priority: .userInitiated) {
                index.entries.filter(matches)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            self.context = context
            self.entries = entries
            self.visibleIDs = entries.prefix(Self.browseLimit).map(\.id)
            self.totalMatches = entries.count
        }
    }

    func close() {
        buildTask?.cancel()
        filterDebouncer.cancel()
        isActive = false
        context = nil
        entries = []
        isLoading = false
        filterText = ""
        visibleIDs = []
        totalMatches = 0
    }

    private func scheduleFilter() {
        filterDebouncer.cancel()
        guard context != nil else { return }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            visibleIDs = entries.prefix(Self.browseLimit).map(\.id)
            totalMatches = entries.count
            return
        }
        let limit = Self.browseLimit
        let entries = entries
        filterDebouncer.schedule { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                // Order-preserving on purpose: this list ranks by size, and
                // the filter narrows that ranking.
                FuzzyMatcher.matchesInEntryOrder(query: query, entries: entries, limit: limit)
            }.value
            guard let self, !Task.isCancelled,
                  self.filterText.trimmingCharacters(in: .whitespaces) == query else {
                return
            }
            self.visibleIDs = results.ids
            self.totalMatches = results.totalMatches
        }
    }
}
