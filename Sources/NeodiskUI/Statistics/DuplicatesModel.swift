// Duplicates tab state. Hashing costs real I/O, so it runs only when asked (or with the auto preference on);
// finished runs persist in the cache's `.nddup` slot so reopening never re-hashes.

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class DuplicatesModel {
    enum Phase {
        case idle
        case scanning
        case finished(DuplicateScanResults)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Hashing progress, 0...1, while `phase == .scanning`.
    private(set) var progress = 0.0
    /// Biggest waste first; superseded by the final results on finish.
    private(set) var liveGroups: [DuplicateGroup] = []
    /// Empty at start, so the whole map dims and confirmed copies light back up.
    private(set) var liveDuplicateIDs: Set<String> = []
    /// For the "Duplicates computed" banner; nil outside `.finished`.
    private(set) var computedAt: Date?
    /// The group the user drilled into, if any.
    private(set) var openGroup: DuplicateGroup?

    /// Minimum file size the finder uses; part of the result cache key.
    nonisolated static let minimumFileSize = DuplicateFinder.defaultMinimumFileSize

    /// Cached because the union would otherwise be rebuilt every render.
    @ObservationIgnored private var allDuplicateIDs: Set<String> = []
    /// Which group each duplicate belongs to, so clicking a copy on the
    /// treemap can open its group.
    @ObservationIgnored private var groupIndexByNodeID: [String: Int] = [:]
    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Publishing re-renders the treemap highlight, so batches coalesce on a fixed cadence.
    @ObservationIgnored private var pendingLiveGroups: [DuplicateGroup] = []
    @ObservationIgnored private var liveFlushTask: Task<Void, Never>?
    private static let liveFlushInterval: Duration = .milliseconds(300)
    /// The snapshot the current phase belongs to; a scan finishing after
    /// the displayed tree changed must not publish stale results.
    @ObservationIgnored private var scannedSnapshotID: UUID?
    /// Drops stale cache-load completions after a snapshot change or a scan
    /// starting under them.
    @ObservationIgnored private var loadGeneration = 0

    init(coordinator: ScanCoordinator, snapshotCache: ScanSnapshotCache) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var results: DuplicateScanResults? {
        if case .finished(let results) = phase { return results }
        return nil
    }

    /// Hashing needs a complete snapshot and no scan already running.
    var canScan: Bool {
        coordinator.snapshot?.isComplete == true
            && !isScanning
    }

    var highlightedNodeIDs: Set<String>? {
        if let openGroup { return Set(openGroup.nodeIDs) }
        switch phase {
        case .finished:
            guard !allDuplicateIDs.isEmpty else { return nil }
            return allDuplicateIDs
        case .scanning:
            return liveDuplicateIDs
        case .idle, .failed:
            return nil
        }
    }

    func startScan() {
        guard canScan, let snapshot = coordinator.snapshot else { return }
        let store = snapshot.treeStore
        let snapshotID = snapshot.id
        let target = snapshot.target
        scannedSnapshotID = snapshotID
        // A hashing run supersedes any in-flight cache load for this tab.
        loadGeneration += 1
        phase = .scanning
        progress = 0
        computedAt = nil
        openGroup = nil
        allDuplicateIDs = []
        groupIndexByNodeID = [:]
        resetLiveState()
        scanTask?.cancel()
        // Built in method scope, not inside the detached work, so the
        // sendable hashing closures never touch the model directly.
        let reportProgress: @Sendable (DuplicateScanProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.scannedSnapshotID == snapshotID else { return }
                self.progress = max(self.progress, update.fractionCompleted)
            }
        }
        let reportPartial: @Sendable ([DuplicateGroup]) -> Void = { [weak self] groups in
            guard let self else { return }
            Task { @MainActor in
                guard self.scannedSnapshotID == snapshotID, self.isScanning else { return }
                self.enqueueLiveGroups(groups)
            }
        }
        scanTask = Task { [weak self, snapshotCache] in
            // Saved on every exit: completed hashes are valid whether the run finished, failed or was superseded.
            let hashCache = await snapshotCache.loadDuplicateHashCache()
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try await DuplicateFinder.findDuplicates(
                        in: store,
                        minimumFileSize: Self.minimumFileSize,
                        hashCache: hashCache,
                        onProgress: reportProgress,
                        onPartial: reportPartial
                    )
                }.cancellableValue
                await snapshotCache.saveDuplicateHashCache(hashCache)
                guard let self, !Task.isCancelled,
                      self.scannedSnapshotID == snapshotID else { return }
                let now = Date()
                self.computedAt = now
                self.apply(results: results)
                // Persist so the next open (this launch or after relaunch)
                // shows the result without re-hashing.
                await snapshotCache.saveDuplicateResults(
                    results,
                    computedAt: now,
                    forTargetID: target.id,
                    minimumFileSize: Self.minimumFileSize
                )
            } catch is CancellationError {
                // cancelScan / snapshotDidChange already reset the phase.
                await snapshotCache.saveDuplicateHashCache(hashCache)
            } catch {
                await snapshotCache.saveDuplicateHashCache(hashCache)
                guard let self, self.scannedSnapshotID == snapshotID else { return }
                self.resetLiveState()
                self.openGroup = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Shared by the live finish and the cache load so highlighting and click-to-open behave the same.
    private func apply(results: DuplicateScanResults) {
        allDuplicateIDs = Set(results.groups.flatMap(\.nodeIDs))
        var indexByNodeID: [String: Int] = [:]
        for (index, group) in results.groups.enumerated() {
            for nodeID in group.nodeIDs {
                indexByNodeID[nodeID] = index
            }
        }
        groupIndexByNodeID = indexByNodeID
        resetLiveState()
        phase = .finished(results)
    }

    /// The first batch publishes immediately so the sidebar reacts the moment anything confirms.
    private func enqueueLiveGroups(_ groups: [DuplicateGroup]) {
        pendingLiveGroups.append(contentsOf: groups)
        guard liveFlushTask == nil else { return }
        if liveGroups.isEmpty {
            flushLiveGroups()
            return
        }
        liveFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.liveFlushInterval)
            guard let self, !Task.isCancelled else { return }
            self.liveFlushTask = nil
            self.flushLiveGroups()
        }
    }

    private func flushLiveGroups() {
        guard !pendingLiveGroups.isEmpty else { return }
        for group in pendingLiveGroups {
            liveDuplicateIDs.formUnion(group.nodeIDs)
        }
        liveGroups.append(contentsOf: pendingLiveGroups)
        pendingLiveGroups.removeAll()
        // Same order as the final results, so finishing only appends context
        // (banner, refresh) without reshuffling what the user is looking at.
        liveGroups.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
            return $0.id < $1.id
        }
    }

    private func resetLiveState() {
        liveFlushTask?.cancel()
        liveFlushTask = nil
        pendingLiveGroups = []
        liveGroups = []
        liveDuplicateIDs = []
    }

    /// Never hashes: a miss leaves the idle prompt so the scan stays opt-in.
    func loadIfNeeded() {
        loadCachedResults(orScanIfMissing: false)
    }

    /// Hashes on a miss only when `scanIfMissing` is set; a no-op unless the tab is idle and unhandled.
    func loadCachedResults(orScanIfMissing scanIfMissing: Bool) {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        guard case .idle = phase, scannedSnapshotID != snapshot.id else { return }
        let snapshotID = snapshot.id
        let target = snapshot.target
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self, snapshotCache] in
            let cached = await snapshotCache.loadDuplicateResults(
                forTargetID: target.id,
                minimumFileSize: Self.minimumFileSize
            )
            guard let self, self.loadGeneration == generation,
                  self.coordinator.snapshot?.id == snapshotID,
                  case .idle = self.phase else { return }
            if let cached {
                self.scannedSnapshotID = snapshotID
                self.computedAt = cached.computedAt
                self.apply(results: cached.results)
            } else if scanIfMissing {
                self.startScan()
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        progress = 0
        computedAt = nil
        openGroup = nil
        resetLiveState()
    }

    func open(_ group: DuplicateGroup) {
        openGroup = group
    }

    /// Selecting a duplicate opens its group; anything else while a group is open steps back out, so
    /// clicking a dimmed cell is the intuitive "back".
    func handleSelection(of nodeID: String) {
        switch phase {
        case .finished(let results):
            if let index = groupIndexByNodeID[nodeID] {
                openGroup = results.groups[index]
            } else if openGroup != nil {
                openGroup = nil
            }
        case .scanning:
            if let group = liveGroups.first(where: { $0.nodeIDs.contains(nodeID) }) {
                openGroup = group
            } else if openGroup != nil {
                openGroup = nil
            }
        case .idle, .failed:
            return
        }
    }

    func closeGroup() {
        openGroup = nil
    }

    /// Results hold the replaced tree's node IDs, and an in-flight scan may hash files that no longer exist.
    func snapshotDidChange() {
        scanTask?.cancel()
        scanTask = nil
        loadGeneration += 1
        scannedSnapshotID = nil
        phase = .idle
        progress = 0
        computedAt = nil
        openGroup = nil
        allDuplicateIDs = []
        groupIndexByNodeID = [:]
        resetLiveState()
    }
}
