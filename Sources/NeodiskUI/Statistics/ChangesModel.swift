// Changes tab state. The full predecessor tree is released once the cache's compact comparison is built.

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class ChangesModel {
    /// Rows kept after sorting by |delta| — past the biggest movements, the
    /// answer is a rescan, not scrolling.
    nonisolated static let entryLimit = 500

    private(set) var list: ScanChangeList?
    /// When the compared previous scan finished, for the "since …" header.
    private(set) var comparisonDate: Date?
    private(set) var isLoading = false
    /// Survives snapshot changes, so the chosen lens carries across scans.
    var filter: ScanChangeList.Filter = .all

    /// For staleness the snapshot ID can't express (the predecessor rotating under the same tree).
    private(set) var reloadToken = 0

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// Snapshot the current `list` (or in-flight load) was computed for.
    @ObservationIgnored private var loadedSnapshotID: UUID?
    /// Drops stale completions after a snapshot change or newer load.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Weak parent for the diff-availability gate and the previous-snapshot-
    /// missing correction, mirroring DiffModel.
    @ObservationIgnored weak var model: NeodiskViewModel?

    init(coordinator: ScanCoordinator, snapshotCache: ScanSnapshotCache) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
    }

    /// Same gate as the outline's Δ column: the diff exists only when a
    /// baseline (previous snapshot) is available for the displayed target.
    var canCompare: Bool {
        model?.diff.canShow == true
    }

    /// Loading only from the pane keeps a hidden tab from decoding previous snapshots.
    func loadIfNeeded() {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        guard canCompare else {
            // The previous snapshot is gone (cleared or first-ever scan):
            // whatever list is showing describes stale generations.
            list = nil
            comparisonDate = nil
            isLoading = false
            loadedSnapshotID = nil
            return
        }
        guard loadedSnapshotID != snapshot.id else { return }
        loadedSnapshotID = snapshot.id
        // Keep the previous list on screen while a rebase recomputes; the
        // spinner is for the nothing-yet case only.
        isLoading = list == nil
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        let generation = loadGeneration
        let target = snapshot.target
        loadTask = Task { [weak self, snapshotCache] in
            // A persisted diff keyed on exactly these two snapshot files skips decoding the predecessor.
            if let cached = await snapshotCache.loadChangeList(
                forTargetID: target.id, entryLimit: Self.entryLimit
            ) {
                guard !Task.isCancelled, let self, self.loadGeneration == generation,
                      self.coordinator.snapshot?.id == snapshot.id else { return }
                self.isLoading = false
                self.list = cached.list
                self.comparisonDate = cached.comparisonDate
                return
            }

            let comparison = await snapshotCache.comparison(for: snapshot, entryLimit: Self.entryLimit)
            let hasPrevious = await snapshotCache.changeListCacheKey(
                forTargetID: target.id, entryLimit: Self.entryLimit
            ) != nil
            guard !Task.isCancelled, let self, self.loadGeneration == generation,
                  self.coordinator.snapshot?.id == snapshot.id else { return }
            self.isLoading = false
            if let comparison {
                self.list = comparison.list
                self.comparisonDate = comparison.baseline.finishedAt
            } else {
                // Corrupt or vanished predecessor: reflect it so the gate
                // (and the outline's Δ column) disable together.
                self.list = nil
                self.comparisonDate = nil
                self.loadedSnapshotID = nil
                if !hasPrevious {
                    self.model?.session.markPreviousSnapshotMissing(forTargetID: target.id)
                }
            }
        }
    }

    /// A new tree is on screen: the list (and any load in flight) describes
    /// the replaced one.
    func snapshotDidChange() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        loadedSnapshotID = nil
        isLoading = false
        list = nil
        comparisonDate = nil
    }

    /// A loaded list now compares against the wrong generation; the pane recomputes only if on screen.
    func snapshotWasRotated(for target: ScanTarget) {
        guard coordinator.snapshot?.target.id == target.id,
              loadedSnapshotID != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        loadedSnapshotID = nil
        reloadToken += 1
    }

    /// Full clear before a new scan takes the screen (part of the model's
    /// per-scan state reset).
    func reset() {
        snapshotDidChange()
    }
}
