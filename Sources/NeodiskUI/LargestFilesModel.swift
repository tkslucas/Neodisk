//
//  LargestFilesModel.swift
//  Neodisk
//
//  The statistics panel's Largest tab: the whole scan's biggest files as a
//  flat, size-descending list ("what's eating my disk"), with the same
//  fuzzy filter as the drill-in lists. Owned by NeodiskViewModel as
//  `model.largest`. A slice of the shared per-snapshot search index, whose
//  size-descending order is exactly the browse order — loaded lazily when
//  the tab is on screen, not per snapshot.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class LargestFilesModel {
    /// Cap for browsing with no filter typed — past the top files, the
    /// answer is the filter, not scrolling.
    static let browseLimit = 500

    private(set) var isLoading = false
    private(set) var visibleIDs: [String] = []
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
    /// descending; the filter matches against all of them, not just the
    /// visible prefix.
    @ObservationIgnored private var entries: [FileSearchEntry] = []
    @ObservationIgnored private var loadedSnapshotID: UUID?

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.indexService = indexService
    }

    /// Called from the pane whenever it is on screen with a snapshot (tab
    /// switches and partial-snapshot updates alike); no-op when the list
    /// already matches the displayed snapshot. Loading only from the pane
    /// keeps hidden tabs from forcing index builds during scans.
    func loadIfNeeded() {
        guard let snapshot = coordinator.snapshot else { return }
        guard loadedSnapshotID != snapshot.id else { return }
        loadedSnapshotID = snapshot.id
        // Keep the previous list on screen while a partial refresh rebuilds;
        // the spinner is for the nothing-yet case only.
        isLoading = visibleIDs.isEmpty
        loadTask?.cancel()
        loadTask = Task { [weak self, indexService] in
            let index = await indexService.index(for: snapshot)
            let entries = await Task.detached(priority: .userInitiated) {
                index.entries.filter(\.isKindCountable)
            }.value
            guard let self, !Task.isCancelled,
                  self.coordinator.snapshot?.id == snapshot.id else { return }
            self.isLoading = false
            self.entries = entries
            self.applyFilter()
        }
    }

    /// The displayed tree changed: the list holds node IDs of the replaced
    /// tree. The filter text survives (like the outline search query) so a
    /// scan streaming partials doesn't wipe what the user is typing; the
    /// pane's task reloads against the new tree whenever it is visible.
    func snapshotDidChange() {
        loadTask?.cancel()
        filterDebouncer.cancel()
        entries = []
        loadedSnapshotID = nil
        isLoading = false
        visibleIDs = []
        totalMatches = 0
    }

    /// Full clear before a new scan takes the screen (part of the model's
    /// per-scan state reset) — unlike snapshotDidChange, the filter belongs
    /// to the previous location and goes too.
    func reset() {
        snapshotDidChange()
        filterText = ""
    }

    /// Re-ranks the loaded entries for the current filter — the unfiltered
    /// prefix immediately, fuzzy matches after the shared debounce.
    private func scheduleFilter() {
        filterDebouncer.cancel()
        guard !entries.isEmpty else { return }
        applyFilter()
    }

    private func applyFilter() {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            filterDebouncer.cancel()
            visibleIDs = entries.prefix(Self.browseLimit).map(\.id)
            totalMatches = entries.count
            return
        }
        let limit = SearchModel.resultLimit
        let entries = entries
        filterDebouncer.schedule { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                FuzzyMatcher.topMatches(query: query, entries: entries, limit: limit)
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
