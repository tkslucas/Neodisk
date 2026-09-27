//
//  SearchModel.swift
//  Neodisk
//
//  Entire-scan outline search: the query, its debounced fuzzy results, and
//  the Find-menu focus token. Owned by NeodiskViewModel as `model.search`;
//  matches against the shared per-snapshot index (SnapshotSearchIndex).
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class SearchModel {
    /// Fuzzy results are ranked; past the first screenful, the fix is a
    /// longer query, not scrolling.
    static let resultLimit = 100

    struct Results {
        let ids: [String]
        let totalMatches: Int
    }

    /// Search field at the top of the outline: typing filters the outline
    /// down to matching nodes anywhere in the scan. Never navigates or
    /// zooms — the treemap stays put; selecting a result uses the normal
    /// selection sync.
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            schedule()
        }
    }
    private(set) var results: Results?
    /// Bumped by the Find menu command; the outline focuses its field on
    /// change.
    private(set) var focusToken = 0

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let indexService: SearchIndexService
    @ObservationIgnored private let debouncer = SearchDebouncer()

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.indexService = indexService
    }

    func requestFocus() {
        focusToken += 1
    }

    func clear() {
        text = ""
    }

    /// The displayed tree changed (the model already invalidated the shared
    /// index): keep the user's query and re-run it against the new tree
    /// once one is displayed.
    func snapshotDidChange() {
        if !text.isEmpty {
            results = nil
            schedule()
        }
    }

    private func schedule() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            debouncer.cancel()
            results = nil
            return
        }
        guard let snapshot = coordinator.snapshot else {
            debouncer.cancel()
            results = nil
            return
        }
        let snapshotID = snapshot.id
        debouncer.schedule { [weak self] in
            guard let self else { return }

            let index = await self.indexService.index(for: snapshot)
            guard !Task.isCancelled, self.coordinator.snapshot?.id == snapshotID else { return }

            let limit = Self.resultLimit
            let rootID = index.rootID
            let entries = index.entries
            // A newer keystroke cancels this operation; forward that into
            // the detached match so it stops scanning instead of finishing
            // a whole-index pass nobody will read.
            let results = await Task.detached(priority: .userInitiated) {
                // The root row is the whole scan; it never belongs in
                // search results.
                FuzzyMatcher.topMatches(query: query, entries: entries, limit: limit) {
                    $0.id != rootID
                }
            }.cancellableValue
            guard !Task.isCancelled,
                  self.coordinator.snapshot?.id == snapshotID,
                  self.text.trimmingCharacters(in: .whitespaces) == query else {
                return
            }
            self.results = Results(
                ids: results.ids,
                totalMatches: results.totalMatches
            )
        }
    }
}
