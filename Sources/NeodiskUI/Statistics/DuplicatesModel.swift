//
//  DuplicatesModel.swift
//  Neodisk
//
//  Duplicate-finder state for the statistics panel's Duplicates tab: a
//  content scan of the displayed snapshot, the groups it streams in while
//  hashing (rendered live in the pane and on the map), its results, and the
//  drill-in into one duplicate group. Owned by NeodiskViewModel as
//  `model.duplicates`. Hashing costs real I/O, so it only runs asked-for:
//  via the Find Duplicates button, or right after a scan when the opt-in
//  "find duplicates automatically" preference is on.
//
//  A finished run is persisted through the snapshot cache's `.nddup` slot so
//  reopening the tab (this launch or after relaunch) shows the previous
//  result without re-hashing. Loading is snapshot-scoped like everything
//  else and never triggers hashing on its own.
//
//  Read-only, like the app promises: the finder only reads file contents;
//  cleaning up happens in Finder.
//

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
    /// Groups confirmed so far while `phase == .scanning`, biggest waste
    /// first — the live results the pane and the map highlight render as
    /// hashing progresses. Superseded by the final results on finish.
    private(set) var liveGroups: [DuplicateGroup] = []
    /// Union of every live group's copies, for the map-wide highlight while
    /// scanning: empty at start (the whole map dims), growing as confirmed
    /// copies light back up.
    private(set) var liveDuplicateIDs: Set<String> = []
    /// When the finished result was computed (a live scan this session, or the
    /// cached run's timestamp), for the "Duplicates computed …" banner. Nil
    /// outside `.finished`.
    private(set) var computedAt: Date?
    /// The group the user drilled into, if any.
    private(set) var openGroup: DuplicateGroup?

    /// Minimum file size the finder uses; part of the result cache key.
    nonisolated static let minimumFileSize = DuplicateFinder.defaultMinimumFileSize

    /// Every confirmed duplicate, for the map-wide highlight while the
    /// results list is showing. Cached because the union set is derived
    /// per render otherwise.
    @ObservationIgnored private var allDuplicateIDs: Set<String> = []
    /// Which group each duplicate belongs to, so clicking a copy on the
    /// treemap can open its group.
    @ObservationIgnored private var groupIndexByNodeID: [String: Int] = [:]
    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Confirmed groups the finder has reported but the UI hasn't published
    /// yet. Publishing re-renders the treemap highlight, so batches coalesce
    /// on a fixed cadence (like the scan's partial trees) instead of landing
    /// per confirmation.
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

    /// Scanning hashes file contents against the displayed tree, so it needs
    /// a complete snapshot and no scan already running. Cloud snapshots have
    /// no on-disk files to hash, so it never applies to them.
    var canScan: Bool {
        coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.kind != .cloud
            && !isScanning
    }

    /// Nodes lit on the treemap: the open group's copies, every duplicate
    /// while the results list is showing, or — while scanning — the groups
    /// confirmed so far (empty at first, so hashing starts by dimming the
    /// whole map and confirmed copies light back up as they land).
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
            // Per-file hashes from previous runs; unchanged files skip their
            // reads. Saved on every exit — completed hashes are valid work
            // whether the run finished, failed, or was superseded.
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
                }.value
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

    /// Builds the map-wide highlight index (`allDuplicateIDs` plus the
    /// per-node group lookup) and publishes the results as `.finished`. Shared
    /// by the live-scan finish and the cache-load path so treemap highlighting
    /// and click-to-open-group behave identically whether results were just
    /// hashed or loaded from disk.
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

    /// Buffers finder-confirmed groups and publishes them on a fixed cadence.
    /// The first batch publishes immediately so the sidebar reacts the moment
    /// anything confirms; later batches wait out the interval together.
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

    /// Fill an idle tab from a persisted result for the displayed snapshot, if
    /// one is cached; never hashes. Called from the pane when it is on screen,
    /// mirroring ChangesModel.loadIfNeeded — a hit enters `.finished`
    /// immediately, a miss leaves the idle prompt so the scan stays opt-in.
    func loadIfNeeded() {
        loadCachedResults(orScanIfMissing: false)
    }

    /// Load path with an opt-in fallback: tries the persisted result first and,
    /// only on a miss when `scanIfMissing` is set (the "find duplicates
    /// automatically" preference on a restored snapshot), starts a hashing
    /// scan. A running or finished scan already owns the phase, so this is a
    /// no-op unless the tab is idle and the snapshot has not been handled yet.
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

    /// Routes a selection (treemap or outline click) into the drill-in:
    /// selecting a duplicate opens its group — same as clicking the group
    /// row; selecting anything else while a group is open steps back out to
    /// the all-duplicates view, so clicking a dimmed cell is the intuitive
    /// "back". With no group open, non-duplicate selections change nothing.
    /// Live groups behave the same while the scan is still running — a
    /// confirmed group's membership is already final.
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

    /// The displayed tree changed: results and the drill-in hold node IDs of
    /// the replaced tree, and a scan in flight is hashing files that may no
    /// longer exist.
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
