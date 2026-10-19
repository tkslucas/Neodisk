// "Changes since last scan" state, shown while the Changes tab is selected. Prefetch waits briefly so first
// paint gets the cores; opening the tab during the wait requests the comparison immediately.

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class DiffModel {
    /// Non-nil means diff mode: the outline gains a Δ column and sorts by growth.
    private(set) var baseline: ScanSizeBaseline?
    /// Prefetches set it too: the toolbar spinner is how "Changes is being prepared" shows.
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
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Cancelled by any snapshot change, newer prefetch or user load, so a stale baseline never lands late.
    @ObservationIgnored private var prefetchDelayTask: Task<Void, Never>?
    /// Lets first paint (kind catalog, treemap) win the cores; settable so tests skip the wait.
    @ObservationIgnored var prefetchDelay: Duration = .seconds(4)

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// Weak parent: diffing reads and corrects its `cachedScanInfo` and reads the prefetch preference.
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
        return model?.session.cachedScanInfo[snapshot.target.id]?.hasPreviousSnapshot == true
    }

    /// Shows or hides the diff. Idempotent: the model resyncs on every tab
    /// or panel change, so repeated calls with the same value are no-ops.
    func setShowing(_ shouldShow: Bool) {
        if !shouldShow {
            baseline = nil
            // An in-flight load must not resurrect the mode it just left.
            showsWhenLoaded = false
            return
        }
        guard baseline == nil else { return }
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

    /// A prefetched baseline only matches the exact snapshot it was decoded with.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        prefetchDelayTask?.cancel()
        prefetchedBaseline = nil
        showsWhenLoaded = false
        isLoading = false
        if let baseline, snapshot?.target.id != baseline.targetID {
            self.baseline = nil
        }
    }

    /// The baseline on screen now compares against the wrong generation, so rebase it, or prefetch the new
    /// previous snapshot when the tab is away.
    func snapshotWasRotated(for target: ScanTarget) {
        guard coordinator.snapshot?.target.id == target.id else { return }
        prefetchedBaseline = nil
        guard canShow else { return }
        if model?.wantsDiffVisible == true {
            // Right away, not after the prefetch delay; `load` bumps the generation, dropping stale decodes.
            load(for: target, showsOnCompletion: true)
        } else if model?.preferences?.prepareChangesAfterScan ?? true {
            schedulePrefetch(for: target)
        }
    }

    /// For a snapshot shown without rotating the previous slot (a restore, or an unchanged rescan), since no
    /// rotation will prefetch for it.
    func snapshotWasRestored(for target: ScanTarget) {
        guard coordinator.snapshot?.target.id == target.id,
              baseline == nil, !isLoading, canShow else { return }
        if model?.wantsDiffVisible == true {
            load(for: target, showsOnCompletion: true)
        } else if prefetchedBaseline?.targetID != target.id,
                  model?.preferences?.prepareChangesAfterScan ?? true {
            schedulePrefetch(for: target)
        }
    }

    /// Delayed and at `.utility` so first paint isn't fighting the ~1s decode for cores. A user toggle during
    /// the wait goes through `load` immediately.
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
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        let generation = loadGeneration
        guard let snapshot = coordinator.snapshot, snapshot.target.id == target.id else { return }
        loadTask = Task(priority: priority) { [weak self, snapshotCache] in
            let baseline = await snapshotCache.comparison(
                for: snapshot, entryLimit: ChangesModel.entryLimit
            )?.baseline
            let hasPrevious = await snapshotCache.changeListCacheKey(
                forTargetID: target.id, entryLimit: ChangesModel.entryLimit
            ) != nil
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
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
                if !hasPrevious {
                    self.model?.session.markPreviousSnapshotMissing(forTargetID: target.id)
                }
            }
        }
    }
}
