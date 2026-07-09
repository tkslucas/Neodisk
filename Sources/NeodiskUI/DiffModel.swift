//
//  DiffModel.swift
//  Neodisk
//
//  "Changes since last scan" state: the per-node size baseline decoded from
//  the previous snapshot, plus the toggle/loading choreography. Owned by
//  NeodiskViewModel as `model.diff`.
//
//  The baseline usually loads before the toggle is pressed: whenever a
//  complete tree lands on screen — a scan finishing (its predecessor
//  rotating into the previous slot) or a saved snapshot opening without a
//  rescan — the "prepare Changes" preference prefetches the baseline in
//  the background so the toggle responds instantly. That prefetch decodes
//  the whole previous snapshot (~1s of CPU on a big volume), so it waits a
//  few seconds at low priority to let the first paint's kind catalog and
//  treemap win the cores; a user toggle during the wait loads the baseline
//  immediately instead of waiting out the delay.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class DiffModel {
    /// Per-node sizes of the displayed target's previous scan. Non-nil
    /// means "changes since last scan" mode: the outline gains a Δ column
    /// and sorts by growth.
    private(set) var baseline: ScanSizeBaseline?
    /// True while the previous snapshot decodes for diff mode. Prefetches
    /// set it too: the toolbar spinner is how "Changes is being prepared"
    /// shows.
    private(set) var isLoading = false

    /// A baseline decoded ahead of the toggle, waiting to show instantly.
    /// Internal (not private) so tests can observe the prefetch.
    @ObservationIgnored private(set) var prefetchedBaseline: ScanSizeBaseline?
    /// True when the finished load should go on screen: user-initiated
    /// loads always; a prefetch only if the toggle was pressed mid-load.
    @ObservationIgnored private var showsWhenLoaded = false
    /// Bumped whenever an in-flight load's result would be stale (a newer
    /// load, or any snapshot change); older completions are dropped.
    @ObservationIgnored private var loadGeneration = 0
    /// A restore/rotate prefetch waiting out its delay before it starts
    /// decoding. Cancelled by any snapshot change, a newer prefetch, or a
    /// user-initiated load, so a stale baseline never lands late.
    @ObservationIgnored private var prefetchDelayTask: Task<Void, Never>?
    /// How long a restore/rotate prefetch defers its decode so the first
    /// paint (kind catalog + treemap) wins the cores. Instance-settable so
    /// tests can collapse the wait rather than sleep it out.
    @ObservationIgnored var prefetchDelay: Duration = .seconds(4)

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// Weak parent: diffing consults the model's snapshot-cache index
    /// (`cachedScanInfo`), corrects it when the previous snapshot turns
    /// out to be gone, and reads the prefetch preference.
    @ObservationIgnored weak var model: NeodiskViewModel?

    init(coordinator: ScanCoordinator, snapshotCache: ScanSnapshotCache) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
    }

    var isShowing: Bool {
        baseline != nil
    }

    /// Diffing needs a complete live scan on screen and a rotated previous
    /// snapshot on disk.
    var canShow: Bool {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete,
              snapshot.source.isPersistable else { return false }
        return model?.cachedScanInfo[snapshot.target.id]?.hasPreviousSnapshot == true
    }

    func toggle() {
        if baseline != nil {
            baseline = nil
            // An in-flight reload must not resurrect the mode it just left.
            showsWhenLoaded = false
            return
        }
        guard canShow, let target = coordinator.snapshot?.target else { return }
        if let prefetchedBaseline, prefetchedBaseline.targetID == target.id {
            baseline = prefetchedBaseline
            return
        }
        if isLoading {
            // The prefetch is still decoding; show it the moment it lands.
            showsWhenLoaded = true
            return
        }
        load(for: target, showsOnCompletion: true)
    }

    /// A baseline only makes sense against its own target, and a prefetched
    /// one only against the exact snapshot it was decoded alongside — a new
    /// tree on screen invalidates both it and any load in flight.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        loadGeneration += 1
        prefetchDelayTask?.cancel()
        prefetchedBaseline = nil
        showsWhenLoaded = false
        isLoading = false
        if let baseline, snapshot?.target.id != baseline.targetID {
            self.baseline = nil
        }
    }

    /// Saving the displayed snapshot rotated its predecessor. A baseline on
    /// screen now compares against the wrong generation, so rebase it; with
    /// diff mode off, prefetch the fresh previous snapshot instead when the
    /// preference asks for that. Either path needs two scans of this target
    /// on disk — after its first ever scan `canShow` is false and nothing
    /// loads, so the toggle simply stays disabled.
    func snapshotWasRotated(for target: ScanTarget) {
        guard coordinator.snapshot?.target.id == target.id else { return }
        prefetchedBaseline = nil
        if baseline?.targetID == target.id {
            // Diff is on screen against the now-stale predecessor: rebase it
            // right away, not after the prefetch delay.
            load(for: target, showsOnCompletion: true)
        } else if canShow, model?.preferences?.prepareChangesAfterScan ?? true {
            schedulePrefetch(for: target)
        }
    }

    /// A saved snapshot was put on screen without a rescan, so no scan
    /// finish will prefetch for it. Same convenience as after a rotation:
    /// with the preference on, load the baseline so the toggle answers
    /// instantly. `snapshotDidChange` already ran for the restored snapshot,
    /// so there is no stale prefetch or in-flight load to worry about.
    func snapshotWasRestored(for target: ScanTarget) {
        guard coordinator.snapshot?.target.id == target.id,
              baseline == nil, !isLoading,
              prefetchedBaseline?.targetID != target.id,
              canShow, model?.preferences?.prepareChangesAfterScan ?? true else { return }
        schedulePrefetch(for: target)
    }

    /// Defers a restore/rotate baseline prefetch by `prefetchDelay` and runs
    /// its decode at `.utility`, so the first paint's kind catalog and
    /// treemap aren't fighting the ~1s previous-snapshot decode for cores.
    /// Superseded by any snapshot change, a newer prefetch, or a
    /// user-initiated load (all cancel this task and/or bump `loadGeneration`),
    /// so a baseline for a tree no longer on screen never lands. A user toggle
    /// during the wait goes through `load` immediately, unaffected by the delay.
    private func schedulePrefetch(for target: ScanTarget) {
        prefetchDelayTask?.cancel()
        let generation = loadGeneration
        prefetchDelayTask = Task { [weak self] in
            try? await Task.sleep(for: self?.prefetchDelay ?? .zero)
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            // Re-check the preconditions: the wait may have seen a toggle, a
            // load, or a snapshot change claim (or invalidate) the baseline.
            guard self.baseline == nil, !self.isLoading,
                  self.prefetchedBaseline?.targetID != target.id,
                  self.canShow, self.coordinator.snapshot?.target.id == target.id else { return }
            self.load(for: target, showsOnCompletion: false, priority: .utility)
        }
    }

    private func load(
        for target: ScanTarget,
        showsOnCompletion: Bool,
        priority: TaskPriority = .userInitiated
    ) {
        // Any load supersedes a pending prefetch — this is now the load.
        prefetchDelayTask?.cancel()
        isLoading = true
        showsWhenLoaded = showsOnCompletion
        loadGeneration += 1
        let generation = loadGeneration
        Task(priority: priority) { [weak self, snapshotCache] in
            // Decode happens on the cache actor, the million-node baseline
            // build in a detached task; neither blocks the main actor.
            let previous = await snapshotCache.loadPreviousSnapshot(for: target)
            let baseline = await Task.detached(priority: priority) {
                previous.map(ScanSizeBaseline.init)
            }.value
            guard let self, self.loadGeneration == generation else { return }
            self.isLoading = false
            let showsNow = self.showsWhenLoaded
            self.showsWhenLoaded = false
            guard self.coordinator.snapshot?.target.id == target.id else { return }
            if let baseline {
                self.prefetchedBaseline = baseline
                if showsNow {
                    self.baseline = baseline
                }
            } else {
                // The previous snapshot is gone (corrupt and deleted, or
                // cleared): reflect that so the toggle disables.
                self.baseline = nil
                self.model?.markPreviousSnapshotMissing(forTargetID: target.id)
            }
        }
    }
}
