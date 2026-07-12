//
//  ChangesModel.swift
//  Neodisk
//
//  The statistics panel's Changes tab: the explicit added / deleted /
//  renamed / grown / shrunk list of the displayed scan against its
//  predecessor. Owned by NeodiskViewModel as `model.changes`.
//
//  Availability mirrors the outline diff's baseline gating (see
//  DiffModel.canShow): a complete, persistable snapshot on screen and a
//  rotated previous snapshot on disk. The list is computed on demand when
//  the tab is visible — it needs the full previous snapshot (real paths for
//  deleted entries, exact identities for renames), not the hashed baseline,
//  so it decodes the predecessor itself and releases it once the capped
//  entry list is built.
//

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
    /// The subtab filter (All / Added / Deleted). Like the kind pane's
    /// display mode it survives snapshot changes — the chosen lens carries
    /// across scans.
    var filter: ScanChangeList.Filter = .all

    /// Bumped whenever a loaded list goes stale for reasons the snapshot ID
    /// can't express (the previous snapshot rotating under the same displayed
    /// tree). The pane keys its load task on it.
    private(set) var reloadToken = 0

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// Snapshot the current `list` (or in-flight load) was computed for.
    @ObservationIgnored private var loadedSnapshotID: UUID?
    /// Drops stale completions after a snapshot change or newer load.
    @ObservationIgnored private var loadGeneration = 0
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

    /// Called from the pane whenever it is on screen (tab switches, snapshot
    /// changes, rotations); no-op when the list already matches the
    /// displayed snapshot. Loading only from the pane keeps the hidden tab
    /// from decoding previous snapshots nobody is looking at.
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
        loadGeneration += 1
        let generation = loadGeneration
        let target = snapshot.target
        let currentStore = snapshot.treeStore
        Task { [weak self, snapshotCache] in
            // Fast path: a persisted diff keyed on exactly the current and
            // previous snapshot files (written proactively at scan finish, or
            // by a prior open). Skips decoding the predecessor and rebuilding.
            if let cached = await snapshotCache.loadChangeList(
                forTargetID: target.id, entryLimit: Self.entryLimit
            ) {
                guard let self, self.loadGeneration == generation,
                      self.coordinator.snapshot?.id == snapshot.id else { return }
                self.isLoading = false
                self.list = cached.list
                self.comparisonDate = cached.comparisonDate
                return
            }

            let previous = await snapshotCache.loadPreviousSnapshot(for: target)
            let list = await Task.detached(priority: .userInitiated) {
                previous.map {
                    ScanChangeList.build(
                        current: currentStore,
                        previous: $0.treeStore,
                        entryLimit: Self.entryLimit
                    )
                }
            }.value
            guard let self, self.loadGeneration == generation,
                  self.coordinator.snapshot?.id == snapshot.id else { return }
            self.isLoading = false
            if let list {
                self.list = list
                self.comparisonDate = previous?.finishedAt
                // Write the freshly built diff back so the next open (this
                // launch or after relaunch) hits the fast path.
                await snapshotCache.saveChangeList(
                    list,
                    comparisonDate: previous?.finishedAt,
                    forTargetID: target.id,
                    entryLimit: Self.entryLimit
                )
            } else {
                // Corrupt or vanished predecessor: reflect it so the gate
                // (and the outline's Δ column) disable together.
                self.list = nil
                self.comparisonDate = nil
                self.loadedSnapshotID = nil
                self.model?.markPreviousSnapshotMissing(forTargetID: target.id)
            }
        }
    }

    /// A new tree is on screen: the list (and any load in flight) describes
    /// the replaced one.
    func snapshotDidChange() {
        loadGeneration += 1
        loadedSnapshotID = nil
        isLoading = false
        list = nil
        comparisonDate = nil
    }

    /// Saving the displayed snapshot rotated its predecessor: a loaded list
    /// now compares against the wrong generation. Invalidate and let the
    /// pane's task recompute if (and only if) the tab is on screen.
    func snapshotWasRotated(for target: ScanTarget) {
        guard coordinator.snapshot?.target.id == target.id,
              loadedSnapshotID != nil else { return }
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
