// The scan lifecycle around the snapshot cache: startScan's restore / refresh / live choice, auto-rescan,
// the sidebar's cache index and persisting finished scans with their sidecars.

import Foundation
import Observation
import NeodiskKit
import NeodiskAppModel

@MainActor
@Observable
final class ScanSessionModel {
    /// Per target path: what opens instantly from cache, "Scanned … ago", and the last scan's duration.
    private(set) var cachedScanInfo: [String: CachedScanInfo] = [:]
    /// Shown while a cached snapshot stands in for a skipped auto-rescan:
    /// the floating notice offering the rescan the app didn't start.
    var snapshotNotice: SnapshotNotice?

    /// Set when an explicit new scan took a contended disk from a running
    /// scan the app stopped for it — a passive strip mention, dismissable.
    var supersededScanNotice: SupersededScanNotice?

    /// Running scans NOT on screen (demoted on navigate-away); the foreground one lives on the coordinator.
    /// Invariant: one running session per target across both.
    private(set) var activeSessions: [String: ScanSession] = [:]

    struct SupersededScanNotice: Equatable {
        let displayName: String
    }

    /// Smart policy: rescans faster than this last time auto-start; slower ones show the snapshot and leave
    /// rescanning to the user.
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
    /// Injected so tests can force same/different-device, network and cloud verdicts.
    @ObservationIgnored var sourceIdentityProvider: (ScanTarget) -> ScanSourceIdentity
    /// For the per-scan UI reset when a new scan or snapshot takes the screen. Assigned right after init.
    @ObservationIgnored weak var model: NeodiskViewModel?

    /// Fires once a snapshot's whole persistence pipeline has run, so tests needn't poll under main-actor load.
    @ObservationIgnored var onSnapshotPersistedForTesting: ((ScanSnapshot) -> Void)?

    init(
        coordinator: ScanCoordinator,
        snapshotCache: ScanSnapshotCache,
        kinds: KindStatsModel,
        diff: DiffModel,
        changes: ChangesModel,
        duplicates: DuplicatesModel,
        sourceIdentityProvider: @escaping (ScanTarget) -> ScanSourceIdentity = { ScanSourceIdentity.detect(for: $0) }
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.kinds = kinds
        self.diff = diff
        self.changes = changes
        self.duplicates = duplicates
        self.sourceIdentityProvider = sourceIdentityProvider
    }

    // MARK: - Session registry

    /// On screen or demoted to the background: the single source of truth for "is this scanning".
    func activeSession(forTargetID targetID: String) -> ScanSession? {
        if let displayed = coordinator.displayedSession,
           displayed.target.id == targetID, displayed.state == .running {
            return displayed
        }
        if let background = activeSessions[targetID], background.state == .running {
            return background
        }
        return nil
    }

    /// Stops the running scan of a target — the foreground one via the
    /// coordinator, a background one directly — and drops it from the registry.
    func stopSession(forTargetID targetID: String) {
        if let background = activeSessions.removeValue(forKey: targetID) {
            background.cancel()
        }
        if coordinator.displayedSession?.target.id == targetID {
            coordinator.stopScan()
        }
    }

    /// One running session per target: a background scan of the target we are
    /// about to display is superseded before the new display takes over.
    private func supersedeBackgroundSession(forTargetID targetID: String) {
        guard let existing = activeSessions.removeValue(forKey: targetID) else { return }
        existing.cancel()
    }

    /// The single session factory: every session is born here, so display vs. background is a routing
    /// decision (which one the coordinator shows), not a wiring one.
    private func makeSession(
        _ target: ScanTarget,
        options: ScanOptions,
        kind: ScanSession.Kind,
        baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil,
        showsStandInWhileScanning: Bool,
        refreshBaseline: ScanSnapshot? = nil
    ) -> ScanSession {
        let session = ScanSession(
            target: target,
            options: options,
            kind: kind,
            service: coordinator.scanService,
            baselineProvider: baselineProvider,
            showsStandInWhileScanning: showsStandInWhileScanning,
            refreshBaseline: refreshBaseline,
            progress: ScanProgressState(),
            progressThrottleDuration: coordinator.progressThrottleDuration
        )
        session.onSnapshotUpdate = { [weak self] session in
            self?.coordinator.showDisplayedPartial(from: session)
        }
        session.onCompletion = { [weak self] session in
            self?.sessionDidComplete(session)
        }
        return session
    }

    /// Starts a cold live scan of `target` and puts its growing map on screen.
    private func startLiveScan(_ target: ScanTarget, options: ScanOptions) {
        FeltTiming.noteScanStart()
        let session = makeSession(target, options: options, kind: .fresh, showsStandInWhileScanning: false)
        coordinator.attach(session, mode: .live, displaying: nil)
        session.start()
    }

    /// The displayed or recently displayed snapshot holds the screen and is the incremental baseline;
    /// otherwise `baselineProvider` seeds the engine and a decode lands the stand-in later.
    @discardableResult
    private func startRefreshScan(
        _ target: ScanTarget,
        options: ScanOptions,
        baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil
    ) -> ScanSession {
        // Prefer what the display already holds: no decode, and it IS the target's last complete scan.
        let retained = coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.id == target.id
            ? coordinator.snapshot
            : coordinator.recentSnapshot(forTargetID: target.id)
        let effectiveBaselineProvider = retained.map { r in { @Sendable in r } } ?? baselineProvider

        FeltTiming.noteScanStart()
        let session = makeSession(
            target,
            options: options,
            kind: effectiveBaselineProvider == nil ? .fresh : .refresh,
            baselineProvider: effectiveBaselineProvider,
            showsStandInWhileScanning: true,
            refreshBaseline: retained
        )
        if retained != nil {
            FeltTiming.noteCachedSnapshotDisplayed()
        }
        coordinator.attach(
            session,
            mode: .refreshBehindCache(scanDate: retained.map { $0.finishedAt ?? $0.startedAt }),
            displaying: retained
        )
        session.start()
        return session
    }

    /// One handler for the scan on screen and a demoted one, told apart by what the coordinator displays.
    /// Both persist the same way; the diff/changes rotation hooks self-gate to the displayed target.
    private func sessionDidComplete(_ session: ScanSession) {
        let isDisplayed = coordinator.displayedSession === session
        if isDisplayed {
            coordinator.settleDisplayedCompletion(from: session)
        } else if activeSessions[session.target.id] === session {
            activeSessions.removeValue(forKey: session.target.id)
        }

        guard session.state == .finished,
              let snapshot = session.latestSnapshot, snapshot.isComplete else { return }

        if isDisplayed {
            // The scan the user was watching finished, so the "stopped the old
            // scan for this one" mention has served its purpose.
            supersededScanNotice = nil
            persistCompletedSnapshot(snapshot)
            if preferences?.autoScanDuplicates == true {
                duplicates.startScan()
            }
        } else {
            coordinator.insertRecentSnapshot(snapshot)
            persistCompletedSnapshot(snapshot)
        }
    }

    /// The session keeps running in the registry; its hooks are gated on the displayed session, so its
    /// partials reach nothing and its finish takes the background path.
    private func demoteToBackground(_ session: ScanSession) {
        coordinator.detach()
        activeSessions[session.target.id] = session
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

    /// Volume totals are wrong without hidden system metadata (.Spotlight-V100, .fseventsd, .Trashes).
    func scanOptions(for target: ScanTarget) -> ScanOptions {
        var options = preferences?.scanOptions ?? ScanOptions()
        if target.kind == .volume {
            options.includeHiddenFiles = true
        }
        return options
    }

    func startScan(_ target: ScanTarget, forcesRescan: Bool = false) {
        // A background scan of this target IS what to show: promote it rather than start a second one.
        let attachable = forcesRescan ? nil : activeSessions[target.id]

        // Leaving a running scan for another target: the concurrent-scan ruling decides whether it keeps
        // running, is stopped, or this target defers to it and shows its cache.
        let navigateAway = evaluateNavigateAway(
            to: target,
            forcesRescan: forcesRescan,
            hasAttachTarget: attachable != nil
        )
        if case .deferredToCache = navigateAway {
            supersededScanNotice = nil
            return
        }

        if let attachable {
            attachBackgroundSession(attachable, to: target)
        } else {
            // A forced rescan cancels this target's background scan first (one running session per target).
            supersedeBackgroundSession(forTargetID: target.id)
            startScanBranch(target, forcesRescan: forcesRescan)
        }

        if case .cancelledRunningScan(let displayName) = navigateAway {
            supersededScanNotice = SupersededScanNotice(displayName: displayName)
        } else {
            supersededScanNotice = nil
        }
    }

    /// Resumes the display exactly as it left the screen (live partials, or a refresh's stand-in); the
    /// per-session progress keeps the bar where it was.
    private func attachBackgroundSession(_ session: ScanSession, to target: ScanTarget) {
        activeSessions.removeValue(forKey: session.target.id)
        prepareForNewDisplay()
        // A navigation to an existing scan, not a new scan start.
        FeltTiming.noteScanStart(restore: true)

        if session.showsStandInWhileScanning {
            let standIn = session.refreshBaseline
            coordinator.attach(
                session,
                mode: .refreshBehindCache(scanDate: standIn.map { $0.finishedAt ?? $0.startedAt }),
                displaying: standIn
            )
            if standIn != nil {
                FeltTiming.noteCachedSnapshotDisplayed()
            }
        } else {
            coordinator.attach(session, mode: .live, displaying: session.latestSnapshot)
        }
    }

    /// The outcome of leaving a running scan to select a different target.
    private enum NavigateAwayOutcome {
        /// No running scan to leave, or the same target — nothing to decide.
        case none
        /// The running scan was demoted and keeps going in the background.
        case demoted
        /// The running scan was left for the branches to stop; its name feeds
        /// the passive "stopped X for this scan" mention.
        case cancelledRunningScan(String)
        /// This selection deferred to the running scan and displayed the
        /// target from cache instead — the normal branches must not run.
        case deferredToCache
    }

    private func evaluateNavigateAway(
        to target: ScanTarget,
        forcesRescan: Bool,
        hasAttachTarget: Bool
    ) -> NavigateAwayOutcome {
        guard let displayed = coordinator.displayedSession,
              displayed.state == .running,
              displayed.target.id != target.id else { return .none }

        let newScanIsExplicit = forcesRescan || !hasDisplayableCache(for: target)
        let ruling = ScanSourceIdentity.ruling(
            running: sourceIdentityProvider(displayed.target),
            new: sourceIdentityProvider(target),
            newScanIsExplicit: newScanIsExplicit
        )
        switch ruling {
        case .runBoth:
            demoteToBackground(displayed)
            return .demoted
        case .cancelOld:
            // The startScan branches below cancel the on-screen session when
            // they take over the display; name it here for the mention.
            return .cancelledRunningScan(displayed.target.displayName)
        case .deferNew:
            demoteToBackground(displayed)
            // When the target has its own running scan to attach, its live map
            // beats a cached stand-in — attach it instead of deferring.
            if !hasAttachTarget, displayTargetFromCacheDeferringRefresh(target) {
                return .deferredToCache
            }
            // Launch race with nothing cached: no stand-in to defer to, so scan with the old one still running.
            return .demoted
        }
    }

    /// The difference between an implicit refresh (which may defer) and explicit intent (which may not).
    private func hasDisplayableCache(for target: ScanTarget) -> Bool {
        coordinator.recentSnapshot(forTargetID: target.id) != nil
            || cachedScanInfo[target.id] != nil
            || !hasIndexedSnapshotCache
    }

    /// False only in the launch race where nothing is cached yet.
    private func displayTargetFromCacheDeferringRefresh(_ target: ScanTarget) -> Bool {
        if let info = cachedScanInfo[target.id] {
            displaySnapshotWithoutRescan(for: target, info: info)
            return true
        }
        if let recent = coordinator.recentSnapshot(forTargetID: target.id) {
            prepareForNewDisplay()
            coordinator.restoreCompletedSnapshot(recent)
            syncCachedScanDate(with: recent)
            snapshotNotice = SnapshotNotice(for: recent, lastScanDuration: nil)
            snapshotWasRestoredWithoutRescan()
            return true
        }
        return false
    }

    /// The pre-Stage-2 startScan body: the restore / refresh-behind-the-map /
    /// live-scan branch choice for the target that will take the screen.
    private func startScanBranch(_ target: ScanTarget, forcesRescan: Bool) {
        let options = scanOptions(for: target)
        let displaysTargetAlready = coordinator.snapshot?.isComplete == true
            && coordinator.snapshot?.target.id == target.id
        if displaysTargetAlready {
            // A deliberately skipped rescan must not start by accident; the notice and toolbar are the ways in.
            if !forcesRescan, snapshotNotice?.targetID == target.id {
                return
            }
            // Rescan of the location on screen: keep the map, refresh behind it.
            prepareForNewDisplay()
            startRefreshScan(target, options: options)
        } else if !forcesRescan,
                  let info = cachedScanInfo[target.id],
                  shouldSkipAutoRescan(lastScanDuration: info.lastScanDuration) {
            displaySnapshotWithoutRescan(for: target, info: info)
        } else if coordinator.recentSnapshot(forTargetID: target.id) != nil {
            // Displayed earlier this session: shows instantly from memory and is the incremental baseline.
            prepareForNewDisplay()
            startRefreshScan(target, options: options)
        } else if cachedScanInfo[target.id] != nil || !hasIndexedSnapshotCache {
            // Show the persisted snapshot once decoded and refresh behind it; a miss reverts to live partials.
            // One decode feeds both the display and the incremental baseline.
            prepareForNewDisplay()
            let load = Task { [snapshotCache, kinds] in
                await Self.loadSeededSnapshot(for: target, in: snapshotCache, seeding: kinds)
            }
            let session = startRefreshScan(
                target,
                options: options,
                baselineProvider: { await load.value.snapshot }
            )
            restoreCachedSnapshot(
                for: target,
                session: session,
                canCancelRefresh: !forcesRescan,
                load: load
            )
        } else {
            prepareForNewDisplay()
            startLiveScan(target, options: options)
        }
    }


    /// Every startScan/restore branch that replaces what's on screen clears
    /// the pending notice and the per-scan UI state first.
    private func prepareForNewDisplay() {
        snapshotNotice = nil
        model?.resetPerScanState()
    }

    /// Explicit rescans (forcesRescan: true) never consult this.
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
                self.startLiveScan(target, options: self.scanOptions(for: target))
            }
        }
    }

    /// The one way a cached snapshot loads for display: the tiny kind-stats sidecar seeds the kinds first,
    /// or the first render flashes gray. Every restore path must come through here.
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

    /// Lets the sidebar's volume bars color themselves without decoding the snapshot; nil if never scanned.
    func loadKindStatsSidecar(forTargetID targetID: String) async -> KindStatsSidecar? {
        await snapshotCache.loadAuxiliaryData(forTargetID: targetID)
            .flatMap(KindStatsSidecar.decoding)
    }

    /// The sidecar is written after `cachedScanInfo` updates, so reactive readers (the sidebar bars) must key
    /// on this, not on the scan date, or they reload too early.
    private(set) var kindStatsSidecarGeneration = 0

    /// The displayed scan's persisted kind stats use the old categories: rewrite them.
    func categoryRulesDidChange() {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete,
              cachedScanInfo[snapshot.target.id] != nil else { return }
        let snapshotCache = snapshotCache
        Task { [weak self] in
            await Self.saveKindStatsSidecar(for: snapshot, in: snapshotCache)
            self?.kindStatsSidecarGeneration += 1
        }
    }

    /// Only the no-rescan endings need this; a refresh's finish writes a fresh sidecar anyway.
    private static func backfillKindStatsSidecarIfStale(
        _ sidecar: KindStatsSidecar?,
        for cached: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        guard sidecar?.matches(cached) != true else { return }
        await saveKindStatsSidecar(for: cached, in: snapshotCache)
    }

    /// Utility priority: the same O(nodes) pass a restore would otherwise pay at the worst moment.
    private static func saveKindStatsSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        let sidecarData = await Task.detached(priority: .utility) {
            try? KindStatsSidecar.make(for: snapshot).encoded()
        }.cancellableValue
        guard !Task.isCancelled, let sidecarData else { return }
        await snapshotCache.saveAuxiliaryData(sidecarData, forTargetID: snapshot.target.id)
    }

    /// Diffs a just-saved snapshot against its rotated predecessor off the main actor, so the Changes tab
    /// opens instantly. No-op without a predecessor.
    private static func saveChangeListSidecar(
        for snapshot: ScanSnapshot,
        in snapshotCache: ScanSnapshotCache
    ) async {
        _ = await snapshotCache.comparison(for: snapshot, entryLimit: ChangesModel.entryLimit)
    }

    /// No refresh runs behind this snapshot, so no finish will run the usual conveniences: run them here.
    private func snapshotWasRestoredWithoutRescan() {
        guard let snapshot = coordinator.snapshot, snapshot.isComplete else { return }
        diff.snapshotWasRestored(for: snapshot.target)
        // Prefer a persisted duplicate result; relaunch never silently re-hashes.
        duplicates.loadCachedResults(orScanIfMissing: preferences?.autoScanDuplicates == true)
    }

    /// The decoded snapshot is the truth: adopt its date if the index disagrees (e.g. another process wrote it).
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
        session: ScanSession,
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
                // The decode lands on the session, not the display: a demoted refresh must keep its stand-in for a return.
                guard session.state == .running else { return }
                session.refreshBaseline = cached
                self.coordinator.showRefreshBaselineIfAttached(session)
                // The pre-index launch race can start a refresh before we know the last scan was slow: the snapshot
                // proves it, so stop the scan and offer a notice like the indexed path would.
                let lastDuration = cached.finishedAt.map { $0.timeIntervalSince(cached.startedAt) }
                self.syncCachedScanDate(with: cached)
                let standingIn = self.coordinator.displayedSession === session
                    && self.coordinator.snapshot?.id == cached.id
                if canCancelRefresh,
                   shouldSkipAutoRescan(lastScanDuration: lastDuration),
                   standingIn {
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
                } else if standingIn {
                    FileHandle.standardError.write(
                        Data("Neodisk: showing cached scan of \(target.id) while the refresh runs\n".utf8)
                    )
                }
            } else {
                // Corrupt or vanished: stream partials like a cold scan from here. Keep the cache entry if this scan
                // already finished and persisted a fresh snapshot (a demoted scan finishes off screen).
                session.showsStandInWhileScanning = false
                self.coordinator.abandonRefreshBaselineIfAttached(session)
                let freshlyCompleted = session.state == .finished
                    || (self.coordinator.snapshot?.isComplete == true
                        && self.coordinator.snapshot?.target.id == target.id)
                if !freshlyCompleted {
                    self.cachedScanInfo.removeValue(forKey: target.id)
                }
            }
        }
    }

    private func persistCompletedSnapshot(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete, snapshot.source.isPersistable else { return }
        // Optimistic: saving usually rotates the latest snapshot into the previous slot; the save's outcome
        // corrects it (an unchanged rescan skips the rotation).
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

    /// After a subtree splice. The index keeps the last full scan's date and duration (they drive auto-rescan);
    /// only the node count updates. The pre-splice snapshot still rotates into the previous slot.
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
            // Signals the end of the persistence pipeline (success or failure)
            // for the test seam; runs after every await below completes.
            defer { self?.onSnapshotPersistedForTesting?(snapshot) }
            do {
                let outcome = try await snapshotCache.save(snapshot)
                // The save knows the truth: an unchanged rescan skips the rotation.
                self?.setHasPreviousSnapshot(
                    outcome.hasPreviousSnapshot, forTargetID: snapshot.target.id
                )
                if outcome.rotatedPrevious {
                    // The predecessor rotated: an active diff of this target must rebase on it.
                    self?.diff.snapshotWasRotated(for: snapshot.target)
                    self?.changes.snapshotWasRotated(for: snapshot.target)
                } else {
                    // Content-identical rescan: the previous slot still describes the right generation.
                    self?.diff.snapshotWasRestored(for: snapshot.target)
                }
                // Kind stats ride along so the next restore of this
                // snapshot starts with a colored map.
                await Self.saveKindStatsSidecar(for: snapshot, in: snapshotCache)
                self?.kindStatsSidecarGeneration += 1
                await Self.saveChangeListSidecar(for: snapshot, in: snapshotCache)
            } catch {
                DiagnosticLog.cache.error("failed to persist scan snapshot: \(error)")
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

    /// Cache-index bookkeeping for a removed sidebar folder.
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
