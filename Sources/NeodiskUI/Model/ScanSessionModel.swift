//
//  ScanSessionModel.swift
//  Neodisk
//
//  The scan lifecycle around the snapshot cache: startScan's branch choice
//  (restore / refresh-behind-the-map / live scan), the auto-rescan policy and
//  its notice, the cache index the sidebar reads, and persisting finished
//  scans with their kind-stats and change-list sidecars. Owned by
//  NeodiskViewModel as `model.session`.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class ScanSessionModel {
    /// What the snapshot cache holds per target path: which locations open
    /// instantly from cache, the sidebar's "Scanned … ago" subtitles, and
    /// how long the last scan took (whether a rescan should auto-start).
    private(set) var cachedScanInfo: [String: CachedScanInfo] = [:]
    /// Shown while a cached snapshot stands in for a skipped auto-rescan:
    /// the floating notice offering the rescan the app didn't start.
    var snapshotNotice: SnapshotNotice?

    /// Under the smart auto-rescan policy: rescans that finished faster than
    /// this last time keep the original click-to-rescan behavior; slower ones
    /// display their snapshot and leave rescanning to the user (via the
    /// notice or the toolbar).
    static let autoRescanMaxLastScanDuration: TimeInterval = 15

    struct SnapshotNotice: Equatable {
        let targetID: String
        let scanDate: Date
        let lastScanDuration: TimeInterval?

        /// The notice a restored-without-rescan snapshot gets.
        init(for snapshot: ScanSnapshot, lastScanDuration: TimeInterval?) {
            targetID = snapshot.target.id
            scanDate = snapshot.finishedAt ?? snapshot.startedAt
            self.lastScanDuration = lastScanDuration
        }
    }


    /// False until the launch prune has filled `cachedScanInfo`; before that,
    /// scans probe the cache optimistically instead of trusting the index.
    @ObservationIgnored private var hasIndexedSnapshotCache = false

    /// Settings backing scan options and the auto-rescan policy; assigned by
    /// the view model's bindPreferences.
    @ObservationIgnored var preferences: AppPreferences?

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    @ObservationIgnored private let kinds: KindStatsModel
    @ObservationIgnored private let diff: DiffModel
    @ObservationIgnored private let changes: ChangesModel
    @ObservationIgnored private let duplicates: DuplicatesModel
    /// Back-reference for the per-scan UI state reset that must run when a
    /// new scan or snapshot takes the screen — the same idiom DiffModel and
    /// ChangesModel use. Assigned right after init.
    @ObservationIgnored weak var model: NeodiskViewModel?

    init(
        coordinator: ScanCoordinator,
        snapshotCache: ScanSnapshotCache,
        kinds: KindStatsModel,
        diff: DiffModel,
        changes: ChangesModel,
        duplicates: DuplicatesModel
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.kinds = kinds
        self.diff = diff
        self.changes = changes
        self.duplicates = duplicates
    }

    /// Coordinator hook for a finished scan: persist it and run the opt-in
    /// conveniences.
    func scanDidFinish(_ snapshot: ScanSnapshot) {
        persistCompletedSnapshot(snapshot)
        // Opt-in convenience: kick off the duplicate content scan the
        // moment a scan lands, so the Duplicates tab is ready (or at
        // least underway) by the time the user opens it.
        if preferences?.autoScanDuplicates == true {
            duplicates.startScan()
        }
    }

    /// Drops cache entries for locations no longer in the sidebar and
    /// learns which targets can open instantly from cache.
    func pruneAndIndexCache(keepingTargetIDs validTargetIDs: Set<String>) {
        Task { [weak self, snapshotCache] in
            let index = await snapshotCache.pruneAndIndex(keepingTargetIDs: validTargetIDs)
            // A scan finishing during the prune has the newer entry — keep it.
            self?.cachedScanInfo.merge(index) { current, _ in current }
            self?.hasIndexedSnapshotCache = true
        }
    }

    /// Volume totals are wrong without hidden system metadata
    /// (.Spotlight-V100, .fseventsd, .Trashes, …), so volume scans always
    /// include hidden files regardless of the preference.
    func scanOptions(for target: ScanTarget) -> ScanOptions {
        var options = preferences?.scanOptions ?? ScanOptions()
        if target.kind == .volume {
            options.includeHiddenFiles = true
        }
        return options
    }

    func startScan(_ target: ScanTarget, forcesRescan: Bool = false) {
        let options = scanOptions(for: target)
        let displaysTargetAlready = coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.id == target.id
        if displaysTargetAlready {
            // Re-selecting a snapshot whose rescan the app deliberately
            // skipped must not start that rescan by accident — the notice
            // and the toolbar button are the explicit ways in.
            if !forcesRescan, snapshotNotice?.targetID == target.id {
                return
            }
            // Rescan of the location on screen: keep the map, refresh behind it.
            prepareForNewDisplay()
            coordinator.startRefreshScan(target, options: options)
        } else if !forcesRescan,
                  let info = cachedScanInfo[target.id],
                  shouldSkipAutoRescan(lastScanDuration: info.lastScanDuration) {
            // The policy says an unsolicited rescan would hurt (snapshot-only
            // always; smart when the last scan of this location took long):
            // display the snapshot and offer the rescan in a notice instead.
            displaySnapshotWithoutRescan(for: target, info: info)
        } else if coordinator.recentSnapshot(forTargetID: target.id) != nil {
            // Displayed earlier this session: the map appears instantly from
            // memory (startRefreshScan retains it and uses it as the
            // incremental baseline) — no disk decode, no transition screen.
            prepareForNewDisplay()
            coordinator.startRefreshScan(target, options: options)
        } else if cachedScanInfo[target.id] != nil || !hasIndexedSnapshotCache {
            // A persisted snapshot exists (or the launch index isn't ready
            // yet and one might): show it as soon as it decodes, refreshing
            // behind it. A cache miss reverts to live partial streaming
            // within milliseconds. One decode feeds both the display and the
            // refresh scan's incremental baseline.
            prepareForNewDisplay()
            let load = Task { [snapshotCache, kinds] in
                await Self.loadSeededSnapshot(for: target, in: snapshotCache, seeding: kinds)
            }
            coordinator.startRefreshScan(
                target,
                options: options,
                baselineProvider: { await load.value.snapshot }
            )
            restoreCachedSnapshot(for: target, canCancelRefresh: !forcesRescan, load: load)
        } else {
            prepareForNewDisplay()
            coordinator.startScan(target, options: options)
        }
    }


    /// Every startScan/restore branch that replaces what's on screen clears
    /// the pending notice and the per-scan UI state first.
    private func prepareForNewDisplay() {
        snapshotNotice = nil
        model?.resetPerScanState()
    }

    /// Whether the auto-rescan policy wants a cached snapshot displayed
    /// without an unsolicited refresh scan. Explicit rescans
    /// (forcesRescan: true) never consult this.
    private func shouldSkipAutoRescan(lastScanDuration: TimeInterval?) -> Bool {
        switch preferences?.autoRescanPolicy ?? .snapshotOnly {
        case .automatic:
            return false
        case .smart:
            guard let lastScanDuration else { return false }
            return lastScanDuration > Self.autoRescanMaxLastScanDuration
        case .snapshotOnly:
            return true
        }
    }

    /// Shows the persisted snapshot of a location without rescanning it.
    /// Falls back to a live scan when the snapshot turns out unreadable.
    private func displaySnapshotWithoutRescan(for target: ScanTarget, info: CachedScanInfo) {
        prepareForNewDisplay()
        // Displayed earlier this session: skip the disk decode and restore
        // from memory in place — same notice, no loading state.
        if let recent = coordinator.recentSnapshot(forTargetID: target.id) {
            coordinator.restoreCompletedSnapshot(recent)
            syncCachedScanDate(with: recent)
            snapshotNotice = SnapshotNotice(for: recent, lastScanDuration: info.lastScanDuration)
            snapshotWasRestoredWithoutRescan()
            return
        }
        coordinator.beginSnapshotRestore(target)
        Task { [weak self, snapshotCache] in
            let (cached, sidecar) = await Self.loadSeededSnapshot(
                for: target, in: snapshotCache, seeding: self?.kinds
            )
            guard let self else { return }
            guard self.coordinator.phase == .restoring,
                  self.coordinator.selectedTarget?.id == target.id else {
                return
            }
            if let cached {
                self.coordinator.completeSnapshotRestore(cached)
                self.syncCachedScanDate(with: cached)
                self.snapshotNotice = SnapshotNotice(for: cached, lastScanDuration: info.lastScanDuration)
                self.snapshotWasRestoredWithoutRescan()
                await Self.backfillKindStatsSidecarIfStale(
                    sidecar,
                    for: cached,
                    in: snapshotCache
                )
                self.kindStatsSidecarGeneration += 1
            } else {
                // Corrupt or vanished: forget the cache entry and scan live.
                self.cachedScanInfo.removeValue(forKey: target.id)
                self.coordinator.startScan(target, options: self.scanOptions(for: target))
            }
        }
    }

    /// The one way a cached snapshot is loaded for display: the kind-stats
    /// sidecar goes first (it is tiny next to the snapshot) and seeds the
    /// kind model before the decoded tree can land — the ordering that makes
    /// the first render colored instead of gray. Every restore path must
    /// come through here or it silently ships the gray-then-colored flash.
    private static func loadSeededSnapshot(
        for target: ScanTarget,
        in snapshotCache: ScanSnapshotCache,
        seeding kinds: KindStatsModel?
    ) async -> (snapshot: ScanSnapshot?, sidecar: KindStatsSidecar?) {
        let sidecar = await snapshotCache.loadAuxiliaryData(forTargetID: target.id)
            .flatMap(KindStatsSidecar.decoding)
        kinds?.prepareSeed(sidecar)
        let cached = await snapshotCache.loadSnapshot(for: target)
        return (cached, sidecar)
    }

    /// Persisted kind aggregates for a target's cached scan — the sidebar's
    /// volume bars color themselves from these without decoding the
    /// snapshot itself. nil when the target was never scanned (empty bar).
    func loadKindStatsSidecar(forTargetID targetID: String) async -> KindStatsSidecar? {
        await snapshotCache.loadAuxiliaryData(forTargetID: targetID)
            .flatMap(KindStatsSidecar.decoding)
    }

    /// Bumped whenever a kind-stats sidecar lands on disk. The sidecar is
    /// written asynchronously AFTER the snapshot save updates
    /// `cachedScanInfo` (it is an O(nodes) classification pass), so anyone
    /// reading sidecars reactively — the sidebar's volume bars — must key
    /// on this, not on the scan date, or they reload too early and miss it.
    private(set) var kindStatsSidecarGeneration = 0

    /// Snapshots cached before sidecars existed (or whose sidecar went
    /// stale) get one after display, so their next restore is seeded. Only
    /// the no-rescan endings need this — when a refresh scan keeps running,
    /// its finish writes a fresh sidecar through the save path.
    private static func backfillKindStatsSidecarIfStale(
        _ sidecar: KindStatsSidecar?,
        for cached: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        guard sidecar?.matches(cached) != true else { return }
        await saveKindStatsSidecar(for: cached, in: snapshotCache)
    }

    /// Computes and persists the kind-stats sidecar for a complete snapshot.
    /// Utility priority: this is the same O(nodes) classification pass a
    /// restore would otherwise pay at the worst moment.
    private static func saveKindStatsSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let sidecarData = await Task.detached(priority: .utility) {
            try? KindStatsSidecar.make(for: snapshot).encoded()
        }.value
        guard let sidecarData else { return }
        await snapshotCache.saveAuxiliaryData(sidecarData, forTargetID: snapshot.target.id)
    }

    /// Computes and persists the Changes-tab diff for a just-saved snapshot
    /// against its now-rotated predecessor, mirroring the kind-stats sidecar.
    /// Utility priority and off the main actor: it decodes the predecessor
    /// and runs the O(nodes) build the tab would otherwise pay on first open.
    /// A no-op when there is no predecessor to diff against.
    private static func saveChangeListSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let target = snapshot.target
        guard let previous = await snapshotCache.loadPreviousSnapshot(for: target) else { return }
        let currentStore = snapshot.treeStore
        let entryLimit = ChangesModel.entryLimit
        let list = await Task.detached(priority: .utility) {
            ScanChangeList.build(
                current: currentStore,
                previous: previous.treeStore,
                entryLimit: entryLimit
            )
        }.value
        await snapshotCache.saveChangeList(
            list,
            comparisonDate: previous.finishedAt,
            forTargetID: target.id,
            entryLimit: entryLimit
        )
    }

    /// A saved snapshot landed on screen with no refresh scan behind it, so
    /// no scan finish will run the usual conveniences — prefetch the Changes
    /// baseline and optionally start the duplicate scan here instead. (When
    /// a refresh runs behind the snapshot, its finish triggers both anyway.)
    private func snapshotWasRestoredWithoutRescan() {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        diff.snapshotWasRestored(for: snapshot.target)
        // Prefer a persisted duplicate result over re-hashing: load the cached
        // run if present, and only start a fresh scan on a miss when the opt-in
        // preference is on. Relaunch never silently recomputes.
        duplicates.loadCachedResults(orScanIfMissing: preferences?.autoScanDuplicates == true)
    }

    /// The decoded snapshot is the on-disk truth. If the in-memory index
    /// disagrees (another Neodisk process wrote the cache, or the entry
    /// predates a failed save), adopt the snapshot's date so the sidebar's
    /// "Scanned … ago" matches what is actually displayed.
    private func syncCachedScanDate(with snapshot: ScanSnapshot) {
        let date = snapshot.finishedAt ?? snapshot.startedAt
        guard let info = cachedScanInfo[snapshot.target.id],
              abs(info.lastScanDate.timeIntervalSince(date)) > 1 else { return }
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: date,
            lastScanDuration: snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) },
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: info.hasPreviousSnapshot,
            totalAllocatedSize: snapshot.aggregateStats.totalAllocatedSize,
            cloudOnlyLogicalSize: Self.cloudOnlyBytes(of: snapshot)
        )
    }

    private func restoreCachedSnapshot(
        for target: ScanTarget,
        canCancelRefresh: Bool = false,
        load: Task<(snapshot: ScanSnapshot?, sidecar: KindStatsSidecar?), Never>? = nil
    ) {
        Task { [weak self, snapshotCache] in
            let (cached, sidecar): (ScanSnapshot?, KindStatsSidecar?)
            if let load {
                (cached, sidecar) = await load.value
            } else {
                (cached, sidecar) = await Self.loadSeededSnapshot(
                    for: target, in: snapshotCache, seeding: self?.kinds
                )
            }
            guard let self else { return }
            if let cached {
                self.coordinator.displayCachedSnapshot(cached)
                // The pre-index launch race can start a refresh scan before
                // anything reveals that the last scan of this location was
                // expensive. The decoded snapshot itself carries the proof —
                // when the policy would have skipped the rescan (snapshot-only
                // always; smart for a slow last scan; never under automatic),
                // stop the unsolicited scan and offer it as a notice, same
                // as the indexed path would have.
                let lastDuration = cached.finishedAt.map { $0.timeIntervalSince(cached.startedAt) }
                self.syncCachedScanDate(with: cached)
                if canCancelRefresh,
                   shouldSkipAutoRescan(lastScanDuration: lastDuration),
                   self.coordinator.isScanning,
                   self.coordinator.snapshot?.id == cached.id {
                    self.coordinator.restoreCompletedSnapshot(cached)
                    self.snapshotNotice = SnapshotNotice(for: cached, lastScanDuration: lastDuration)
                    self.snapshotWasRestoredWithoutRescan()
                    // The refresh was cancelled, so no scan finish will
                    // write the sidecar this snapshot is missing.
                    await Self.backfillKindStatsSidecarIfStale(
                        sidecar,
                        for: cached,
                        in: snapshotCache
                    )
                    self.kindStatsSidecarGeneration += 1
                } else if self.coordinator.isScanning, self.coordinator.snapshot?.id == cached.id {
                    FileHandle.standardError.write(
                        Data("Neodisk: showing cached scan of \(target.id) while the refresh runs\n".utf8)
                    )
                }
            } else {
                // Corrupt or vanished: forget it and let the live scan
                // stream — unless the scan finished during the probe and
                // just recorded a fresh snapshot for this very target.
                self.coordinator.abandonCachedSnapshotDisplay(forTargetID: target.id)
                let freshlyCompleted = self.coordinator.snapshot?.isComplete == true
                    && self.coordinator.snapshot?.target.id == target.id
                if !freshlyCompleted {
                    self.cachedScanInfo.removeValue(forKey: target.id)
                }
            }
        }
    }

    private func persistCompletedSnapshot(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete, snapshot.source.isPersistable else { return }
        // Saving usually rotates any existing latest snapshot into the
        // previous slot, so this target likely has a diffable previous scan
        // from now on if it had a cache entry before. Optimistic: an
        // unchanged rescan skips the rotation, and the save's outcome
        // corrects the entry (see saveSnapshotToCache).
        let hadCachedSnapshot = cachedScanInfo[snapshot.target.id] != nil
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: snapshot.finishedAt ?? Date(),
            lastScanDuration: snapshot.finishedAt.map { $0.timeIntervalSince(snapshot.startedAt) },
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: hadCachedSnapshot,
            totalAllocatedSize: snapshot.aggregateStats.totalAllocatedSize,
            cloudOnlyLogicalSize: Self.cloudOnlyBytes(of: snapshot)
        )
        saveSnapshotToCache(snapshot)
    }

    /// Persists the displayed snapshot after a subtree splice (rescan of a
    /// folder or expansion of a summarized one) so reopening the location
    /// keeps the refreshed data. Unlike `persistCompletedSnapshot`, the
    /// cache index keeps the last full scan's date and duration: a subtree
    /// refresh says nothing about how long a full rescan of the location
    /// takes (the duration drives the auto-rescan decision) and the
    /// sidebar's "Scanned … ago" keeps describing the full scan. Only the
    /// node count is refreshed. Saving still rotates the pre-splice
    /// snapshot into the previous slot (unless the splice changed nothing),
    /// which keeps diffing meaningful: "what changed since before this
    /// refresh".
    func persistSplicedSnapshot() {
        guard let snapshot = coordinator.snapshot,
              snapshot.isComplete, snapshot.source.isPersistable else { return }
        let existing = cachedScanInfo[snapshot.target.id]
        cachedScanInfo[snapshot.target.id] = CachedScanInfo(
            lastScanDate: existing?.lastScanDate ?? (snapshot.finishedAt ?? Date()),
            lastScanDuration: existing?.lastScanDuration,
            nodeCount: snapshot.treeStore.nodeCount,
            hasPreviousSnapshot: existing != nil,
            totalAllocatedSize: snapshot.aggregateStats.totalAllocatedSize,
            cloudOnlyLogicalSize: Self.cloudOnlyBytes(of: snapshot)
        )
        saveSnapshotToCache(snapshot)
    }

    private func saveSnapshotToCache(_ snapshot: ScanSnapshot) {
        Task { [weak self, snapshotCache] in
            do {
                let outcome = try await snapshotCache.save(snapshot)
                // The optimistic index entry guessed hasPreviousSnapshot
                // from "was there a cache entry"; the save knows the truth
                // (an unchanged rescan skips the rotation, so a target's
                // first rescan may leave the previous slot empty).
                self?.setHasPreviousSnapshot(
                    outcome.hasPreviousSnapshot, forTargetID: snapshot.target.id
                )
                if outcome.rotatedPrevious {
                    // Saving rotated the displayed scan's predecessor; an
                    // active diff of this target must rebase on it, and an
                    // inactive one may prefetch its baseline. A loaded Changes
                    // list compares against the replaced generation too.
                    self?.diff.snapshotWasRotated(for: snapshot.target)
                    self?.changes.snapshotWasRotated(for: snapshot.target)
                } else {
                    // Content-identical rescan: the previous slot (and any
                    // loaded baseline) still describes the right generation.
                    // Prefetch it for the fresh tree like a restore would.
                    self?.diff.snapshotWasRestored(for: snapshot.target)
                }
                // Kind stats ride along so the next restore of this
                // snapshot starts with a colored map.
                await Self.saveKindStatsSidecar(for: snapshot, in: snapshotCache)
                self?.kindStatsSidecarGeneration += 1
                // Compute and persist the change list now, off the main
                // actor, so the first open of the Changes tab is instant
                // instead of paying a predecessor decode plus O(nodes) build.
                await Self.saveChangeListSidecar(for: snapshot, in: snapshotCache)
            } catch {
                FileHandle.standardError.write(
                    Data("Neodisk: failed to persist scan snapshot: \(error)\n".utf8)
                )
            }
        }
    }

    /// The previous snapshot of a target turned out to be unreadable or
    /// gone; reflect that in the cache index so the diff toggle disables.
    func markPreviousSnapshotMissing(forTargetID targetID: String) {
        setHasPreviousSnapshot(false, forTargetID: targetID)
    }

    /// Cloud-only bytes below a snapshot's root, carried into
    /// `cachedScanInfo` so the sidebar's cloud bar works without decoding.
    private static func cloudOnlyBytes(of snapshot: ScanSnapshot) -> Int64 {
        let store = snapshot.treeStore
        return store.node(id: store.rootID)?.cloudOnlyLogicalSize ?? 0
    }

    private func setHasPreviousSnapshot(_ hasPrevious: Bool, forTargetID targetID: String) {
        guard let info = cachedScanInfo[targetID],
              info.hasPreviousSnapshot != hasPrevious else { return }
        cachedScanInfo[targetID] = info.with(hasPreviousSnapshot: hasPrevious)
    }

    /// Cache-index bookkeeping for a removed location (a removed pinned
    /// folder or a signed-out cloud account).
    func removeCachedScanInfo(forTargetID targetID: String) {
        cachedScanInfo.removeValue(forKey: targetID)
    }

    // MARK: - Snapshot cache maintenance

    /// Total disk usage of persisted snapshots, for Settings → Privacy.
    func scanSnapshotCacheSize() async -> Int64 {
        await snapshotCache.totalSizeOnDisk()
    }

    func clearScanSnapshots() async {
        await snapshotCache.removeAll()
        cachedScanInfo = [:]
        coordinator.forgetAllRecentSnapshots()
    }

}

extension CachedScanInfo {
    /// A copy with the diffability bit corrected by a save's outcome; every
    /// other field describes the same cached scan.
    func with(hasPreviousSnapshot: Bool) -> CachedScanInfo {
        CachedScanInfo(
            lastScanDate: lastScanDate,
            lastScanDuration: lastScanDuration,
            nodeCount: nodeCount,
            hasPreviousSnapshot: hasPreviousSnapshot,
            totalAllocatedSize: totalAllocatedSize,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize
        )
    }
}
