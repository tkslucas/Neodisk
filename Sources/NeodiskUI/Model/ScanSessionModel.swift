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

    /// Set when an explicit new scan took a contended disk from a running
    /// scan the app stopped for it — a passive strip mention, dismissable.
    var supersededScanNotice: SupersededScanNotice?

    /// Running scans that are NOT the one on screen, keyed by target id — the
    /// background scans a navigate-away demotion left running. The foreground
    /// scan lives on the coordinator (`displayedSession`), not here, so this
    /// dictionary is exactly the set Stage 3's sidebar rows observe. The
    /// invariant is one running session per target across both.
    private(set) var activeSessions: [String: ScanSession] = [:]

    struct SupersededScanNotice: Equatable {
        let displayName: String
    }

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
    /// Resolves a target's disk identity for the concurrent-scan ruling.
    /// Injected so tests can force same/different-device, network, and cloud
    /// verdicts without touching the filesystem.
    @ObservationIgnored var sourceIdentityProvider: (ScanTarget) -> ScanSourceIdentity
    /// Back-reference for the per-scan UI state reset that must run when a
    /// new scan or snapshot takes the screen — the same idiom DiffModel and
    /// ChangesModel use. Assigned right after init.
    @ObservationIgnored weak var model: NeodiskViewModel?

    /// Test seam fired once a completed snapshot's full persistence pipeline
    /// (cache index, snapshot save, kind-stats sidecar + generation bump,
    /// change list) has run to the end. Tests await it to observe a background
    /// scan's persistence at a deterministic point instead of polling under
    /// the parallel test bundle's main-actor load.
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

    /// The running scan of a target, whether it is the one on screen or a
    /// demoted background scan — the single source of truth for "is this
    /// location scanning right now".
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

    /// The single scan-session factory: constructs a session on the
    /// coordinator's scan service and wires its hooks to route back here. Every
    /// session — cold, refresh, foreground, or one that will be demoted — is
    /// born here, so display vs. background is a routing decision (which
    /// session the coordinator currently shows), not a wiring one.
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

    /// Starts a refresh of `target` behind a complete stand-in. The displayed
    /// or recently displayed snapshot of the same target holds the screen (and
    /// doubles as the incremental baseline); otherwise `baselineProvider` seeds
    /// the engine and a decode lands the stand-in on the session later.
    @discardableResult
    private func startRefreshScan(
        _ target: ScanTarget,
        options: ScanOptions,
        baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil
    ) -> ScanSession {
        // Prefer what the display already holds: the on-screen snapshot, or a
        // recently displayed one of the same target. Either keeps the map up
        // through the refresh with no decode, and doubles as the incremental
        // baseline (it IS the target's last complete scan).
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

    /// A scan session reached a terminal state. One handler for both the scan
    /// on screen and a demoted background scan — which it is is decided by
    /// whether the coordinator currently displays it, not by how the hook was
    /// wired. The displayed finish settles the display and runs the on-screen
    /// conveniences (the duplicate scan); a background finish only leaves the
    /// registry and is remembered for an instant return. Both persist through
    /// the same path (cachedScanInfo + snapshot save + kind-stats sidecar +
    /// generation bump → the sidebar's bars refresh). `saveSnapshotToCache`'s
    /// diff/changes rotation hooks self-gate to the displayed target, so a
    /// background save never disturbs a displayed diff of another target.
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
            // Opt-in convenience: kick off the duplicate content scan the
            // moment the on-screen scan lands, so the Duplicates tab is ready
            // (or at least underway) by the time the user opens it.
            if preferences?.autoScanDuplicates == true {
                duplicates.startScan()
            }
        } else {
            coordinator.insertRecentSnapshot(snapshot)
            persistCompletedSnapshot(snapshot)
        }
    }

    /// Detaches the on-screen session from the display and keeps it running as
    /// a background scan: it stays in the registry and its progress keeps
    /// updating its own instance for a sidebar row to observe. Its hooks still
    /// route through the model, which gates them on the displayed session, so
    /// its partials now reach nothing and its finish takes the background path.
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
        // The clicked target may already have a running scan of its own — a
        // background scan a previous navigate-away demoted. Unless the user
        // explicitly forces a fresh rescan, that scan IS what to show: promote
        // it rather than starting a second (one running session per target).
        let attachable = forcesRescan ? nil : activeSessions[target.id]

        // Leaving a still-running scan for a different target: the concurrent-
        // scan ruling decides whether it keeps running in the background, is
        // stopped for this one, or (with nothing to attach) whether this one
        // defers to it and shows a cached map instead.
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
            // A forced rescan of a target with a background scan cancels it
            // first (one running session per target); other selections have
            // nothing to supersede here.
            supersedeBackgroundSession(forTargetID: target.id)
            startScanBranch(target, forcesRescan: forcesRescan)
        }

        if case .cancelledRunningScan(let displayName) = navigateAway {
            supersededScanNotice = SupersededScanNotice(displayName: displayName)
        } else {
            supersededScanNotice = nil
        }
    }

    /// Promotes a running background scan of `target` back to the display: it
    /// leaves the registry (its sidebar background row disappears), per-scan UI
    /// state resets as any navigate-back does, and the coordinator resumes its
    /// display exactly as it left the screen — a cold scan's live partial map,
    /// or a refresh's stand-in with partials still suppressed. Subsequent
    /// partials and the finish flow to the display through the session's hooks,
    /// and the per-session progress keeps the bar where it left off.
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

    /// Applies the concurrent-scan ruling when selecting a target different
    /// from the one currently scanning on screen. Runs before the ordinary
    /// startScan branches.
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
            // Launch race with nothing cached to show: the deferral has no
            // stand-in, so fall through to a normal scan with the old one
            // still running in the background.
            return .demoted
        }
    }

    /// Whether a target has a cached or recently displayed snapshot to stand
    /// in without scanning — the difference between an implicit refresh (which
    /// may defer) and cold, explicit intent (which may not).
    private func hasDisplayableCache(for target: ScanTarget) -> Bool {
        coordinator.recentSnapshot(forTargetID: target.id) != nil
            || cachedScanInfo[target.id] != nil
            || !hasIndexedSnapshotCache
    }

    /// Shows a target from its cache without starting a refresh scan, reusing
    /// the snapshot-only display path and its manual-rescan notice. Returns
    /// false only in the launch race where nothing is cached yet.
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
            // Re-selecting a snapshot whose rescan the app deliberately
            // skipped must not start that rescan by accident — the notice
            // and the toolbar button are the explicit ways in.
            if !forcesRescan, snapshotNotice?.targetID == target.id {
                return
            }
            // Rescan of the location on screen: keep the map, refresh behind it.
            prepareForNewDisplay()
            startRefreshScan(target, options: options)
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
            startRefreshScan(target, options: options)
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
                self.startLiveScan(target, options: self.scanOptions(for: target))
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
                // The decode lands on the SESSION, not the display: if the
                // user navigated away mid-decode the refresh is now a
                // background scan, and the stand-in it belongs to must ride
                // along so a return can still show it. The coordinator applies
                // it to the screen only while this session is the one on it.
                session.refreshBaseline = cached
                self.coordinator.showRefreshBaselineIfAttached(session)
                // The pre-index launch race can start a refresh scan before
                // anything reveals that the last scan of this location was
                // expensive. The decoded snapshot itself carries the proof —
                // when the policy would have skipped the rescan (snapshot-only
                // always; smart for a slow last scan; never under automatic),
                // stop the unsolicited scan and offer it as a notice, same
                // as the indexed path would have.
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
                // Corrupt or vanished: this refresh has no stand-in after all,
                // so it streams partials like a cold scan from here — flip the
                // session's display intent (so a re-attach streams too) and
                // revert its display to live streaming if it is still on
                // screen. Forget the cache entry — but not when this scan has
                // since finished and persisted a fresh snapshot: a demoted
                // background scan completes off screen, so the displayed
                // snapshot is another target's; the session's own terminal
                // state is what says its result superseded the stale cache.
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
            // Signals the end of the persistence pipeline (success or failure)
            // for the test seam; runs after every await below completes.
            defer { self?.onSnapshotPersistedForTesting?(snapshot) }
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
