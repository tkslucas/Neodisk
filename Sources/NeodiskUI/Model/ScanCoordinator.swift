//
//  ScanCoordinator.swift
//  Neodisk
//

import Combine
import Foundation
import Observation
import NeodiskKit

enum AppModelPhase: Equatable, Sendable {
    case idle
    case scanning
    /// A cached snapshot is decoding for display with no scan running —
    /// the deliberate path for locations whose rescan is expensive.
    case restoring
    case displaying
    case failed
}

protocol ScanEventStreaming: Sendable {
    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error>

    /// A refresh of a previously scanned target. The baseline provider hands
    /// over the target's last complete snapshot (typically a cache decode
    /// shared with the display path) so an incremental-capable service can
    /// re-enumerate only what changed; nil means scan from scratch.
    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        baselineProvider: @escaping @Sendable () async -> ScanSnapshot?
    ) -> AsyncThrowingStream<ScanProgressEvent, Error>
}

extension ScanEventStreaming {
    /// Services without an incremental path refresh by scanning again.
    func rescan(
        target: ScanTarget,
        options: ScanOptions,
        baselineProvider: @escaping @Sendable () async -> ScanSnapshot?
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options)
    }
}

extension ScanEngine: ScanEventStreaming {}
extension IncrementalScanService: ScanEventStreaming {}

/// Where the displayed tree comes from and how live scan events treat it —
/// the one place that owns the cached-snapshot/refresh choreography, which
/// used to be re-derived from five fields across two objects.
enum DisplaySource: Equatable, Sendable {
    /// Nothing on screen.
    case none
    /// Live scan results stream to the screen (partials while scanning,
    /// then the finished snapshot).
    case liveStreaming
    /// A previous complete snapshot stands in while a refresh scan runs:
    /// partials are suppressed (a complete stale map beats an incomplete
    /// fresh one) and `.finished` swaps the fresh snapshot in. `scanDate`
    /// is the stand-in's finish date for "Last scanned … — refreshing…",
    /// nil until the cached snapshot has actually decoded and displayed.
    case cachedWhileRefreshing(scanDate: Date?)
    /// A cached snapshot was restored for display with no scan running.
    case restoredWithoutScan
}

enum ScanExpansionResult {
    case skipped
    case cancelled
    case expanded(replacementRootID: FileNodeRecord.ID)
    case failed(message: String)
}

@MainActor
final class ScanProgressState: ObservableObject {
    @Published var metrics: ScanMetrics

    init(metrics: ScanMetrics = ScanMetrics()) {
        self.metrics = metrics
    }
}

@MainActor
@Observable
final class ScanCoordinator {
    var phase: AppModelPhase = .idle
    var snapshot: ScanSnapshot? {
        didSet {
            // Every complete snapshot that reaches the screen — scan finish,
            // cached display, restore, node removal — is the freshest truth
            // for its target and becomes the instant-display copy. Partials
            // (isComplete == false) never land here.
            if let snapshot, snapshot.isComplete {
                rememberRecentSnapshot(snapshot)
            }
            onSnapshotChange?(snapshot)
        }
    }
    var selectedTarget: ScanTarget?
    private(set) var scanErrorMessage: String?
    private(set) var expandingNodeID: FileNodeRecord.ID?
    /// See DisplaySource — all transitions live in this class.
    private(set) var displaySource: DisplaySource = .none

    /// The scan whose stream and progress currently drive the display. Each
    /// session owns a distinct `ScanProgressState`, so `progress` changes
    /// identity when the displayed session does — this is tracked (not
    /// `@ObservationIgnored`) precisely so `progress` readers re-bind when the
    /// displayed session swaps (a demoted background scan, a new foreground
    /// scan). `idleProgress` stands in between scans.
    private(set) var displayedSession: ScanSession?
    @ObservationIgnored private let idleProgress: ScanProgressState

    /// The metrics of the scan on screen — the displayed session's own
    /// progress, falling back to the idle instance between scans.
    var progress: ScanProgressState {
        displayedSession?.progress ?? idleProgress
    }

    /// The scan service and throttle back both node expansion here and the
    /// scan sessions ScanSessionModel constructs — the single scan-session
    /// factory reads them so all sessions share this coordinator's service.
    @ObservationIgnored let scanService: any ScanEventStreaming
    @ObservationIgnored let progressThrottleDuration: Duration
    @ObservationIgnored private let snapshotTransformService: any ScanSnapshotTransforming

    /// True while a refresh scan runs behind a displayed cached snapshot.
    var suppressesPartialEvents: Bool {
        if case .cachedWhileRefreshing = displaySource {
            return true
        }
        return false
    }

    /// Finish date of the cached snapshot currently standing in for live
    /// results; the scan strip uses it for "Last scanned … — refreshing…".
    var displayedCachedScanDate: Date? {
        if case .cachedWhileRefreshing(let scanDate) = displaySource {
            return scanDate
        }
        return nil
    }

    /// The last few complete snapshots displayed this session, by target ID —
    /// switching back to one of them shows its map instantly with no cache
    /// decode, then refreshes behind it. The map holds plain references (the
    /// currently displayed snapshot is usually one of them), so the memory
    /// cost is only the non-displayed tail, bounded by a total node budget.
    @ObservationIgnored private var recentSnapshotsByTargetID: [String: ScanSnapshot] = [:]
    /// Least-recently-displayed first.
    @ObservationIgnored private var recentSnapshotTargetIDs: [String] = []
    private static let maxRecentSnapshots = 4
    private static let recentSnapshotNodeBudget = 4_000_000

    @ObservationIgnored private var expandTask: Task<ScanExpansionResult, Never>?
    @ObservationIgnored private var activeExpansionID: UUID?
    /// Fires after every displayed-snapshot change (partials included) with
    /// the new value — the @Observable replacement for the old `$snapshot`
    /// publisher the view model subscribed to.
    @ObservationIgnored var onSnapshotChange: ((ScanSnapshot?) -> Void)?

    init(
        scanService: any ScanEventStreaming = ScanEngine(),
        snapshotTransformService: any ScanSnapshotTransforming = ScanSnapshotTransformService(),
        progressThrottleDuration: Duration = .milliseconds(100),
        progress: ScanProgressState = ScanProgressState()
    ) {
        self.scanService = scanService
        self.snapshotTransformService = snapshotTransformService
        self.progressThrottleDuration = progressThrottleDuration
        self.idleProgress = progress
    }

    var scanMetrics: ScanMetrics {
        get { progress.metrics }
        set { progress.metrics = newValue }
    }

    var isScanning: Bool {
        phase == .scanning
    }

    var canRescan: Bool {
        selectedTarget != nil && !isScanning && phase != .restoring
    }

    var snapshotSource: ScanSnapshotSource {
        snapshot?.source ?? .live
    }

    /// How live events treat the display of a newly attached session — the
    /// two shapes `beginScan` used to fork on, now named so a re-attached
    /// background scan resumes in the same shape it left the screen.
    enum AttachMode: Equatable {
        /// A cold scan streaming to the screen: partials display as they grow.
        case live
        /// A refresh runs behind a complete stand-in: partials are suppressed
        /// until the fresh finish. `scanDate` is the stand-in's finish date for
        /// "Last scanned … — refreshing…", nil until a stand-in has displayed.
        case refreshBehindCache(scanDate: Date?)
    }

    /// Makes `session` the displayed scan and sets the display up for `mode`,
    /// standing `displaying` in on screen (a live partial for a re-attached
    /// cold scan, a complete stand-in for a refresh, or nil for a scan that
    /// has nothing to show yet). The single path that puts a scan on screen,
    /// for both freshly created and re-attached background sessions. The
    /// caller (ScanSessionModel) has already reset per-scan UI state and wired
    /// the session's hooks; whatever was displayed is cancelled unless a
    /// demote detached it first.
    func attach(_ session: ScanSession, mode: AttachMode, displaying standIn: ScanSnapshot?) {
        stopScan(resetState: false)

        selectedTarget = session.target
        scanErrorMessage = nil
        phase = .scanning

        snapshot = standIn
        switch mode {
        case .live:
            displaySource = .liveStreaming
        case .refreshBehindCache(let scanDate):
            displaySource = .cachedWhileRefreshing(scanDate: scanDate)
        }

        // Each session owns its progress, so binding the displayed session
        // rebinds `progress` to its accumulated metrics — a re-attached
        // background scan keeps its bar where it left off (monotonic across
        // detach/re-attach), a fresh session starts from zero.
        displayedSession = session
    }

    /// Shows a refresh session's decoded stand-in — but only while that very
    /// session is the one on screen and still suppressing partials with
    /// nothing complete yet shown. A decode that lands after the session was
    /// demoted (or the display moved on) is ignored here; the snapshot stays on
    /// `session.refreshBaseline` so a re-attach can still show it.
    func showRefreshBaselineIfAttached(_ session: ScanSession) {
        guard session === displayedSession,
              let cached = session.refreshBaseline, cached.isComplete,
              isScanning,
              case .cachedWhileRefreshing = displaySource,
              snapshot?.isComplete != true else {
            return
        }
        FeltTiming.noteCachedSnapshotDisplayed()
        apply(snapshot: cached)
        displaySource = .cachedWhileRefreshing(scanDate: cached.finishedAt ?? cached.startedAt)
    }

    /// Enters the restore phase: a cached snapshot is decoding for display
    /// and no scan will run until the user asks for one. The detail view
    /// shows a lightweight loading state until `completeSnapshotRestore`
    /// swaps the decoded snapshot in.
    func beginSnapshotRestore(_ target: ScanTarget, prepare: () -> Void = {}) {
        stopScan(resetState: false)
        prepare()

        FeltTiming.noteScanStart(restore: true)

        selectedTarget = target
        phase = .restoring
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        snapshot = nil
        displaySource = .none
    }

    /// Displays the decoded snapshot of a restore begun with
    /// `beginSnapshotRestore`. Ignored when the user has moved on (another
    /// target selected, or a scan started) while the decode ran.
    func completeSnapshotRestore(_ snapshot: ScanSnapshot) {
        guard phase == .restoring,
              snapshot.isComplete,
              selectedTarget?.id == snapshot.target.id else {
            return
        }
        restoreCompletedSnapshot(snapshot)
    }

    /// Reverts a refresh session to normal live streaming when the stand-in it
    /// was waiting for turned out to be unreadable — but only while that
    /// session is still the one on screen.
    func abandonRefreshBaselineIfAttached(_ session: ScanSession) {
        guard session === displayedSession,
              isScanning,
              case .cachedWhileRefreshing = displaySource,
              snapshot?.isComplete != true else {
            return
        }
        displaySource = .liveStreaming
    }

    /// The displayed session recorded a new partial tree — show it unless a
    /// stand-in snapshot is holding the screen for a refresh. Self-gates on the
    /// displayed session so a background scan's partials reach nothing.
    func showDisplayedPartial(from session: ScanSession) {
        guard session === displayedSession, !suppressesPartialEvents else { return }
        guard let partial = session.latestSnapshot, !partial.isComplete else { return }
        snapshot = partial
    }

    /// The displayed session reached a terminal state — settle the display and
    /// phase from it. Self-gates on the displayed session; a background scan's
    /// completion (persistence, LRU) is the session model's concern. The finish
    /// case updates the display only; the model persists off the same event.
    func settleDisplayedCompletion(from session: ScanSession) {
        guard session === displayedSession else { return }

        switch session.state {
        case .finished:
            guard let finished = session.latestSnapshot, finished.isComplete else { return }
            FeltTiming.noteEngineFinished(snapshotID: finished.id)
            apply(snapshot: finished)
            displaySource = .liveStreaming
            phase = .displaying
        case .failed(let message):
            displaySource = .none
            phase = .failed
            scanErrorMessage = message
        case .cancelled:
            phase = snapshot == nil ? .idle : .displaying
        case .running:
            break
        }
    }

    /// Releases the displayed session WITHOUT cancelling it: the scan keeps
    /// running, and the caller (the session model) keeps it in the
    /// active-session registry as a background scan (its hooks already route
    /// through the model, which gates them on the displayed session). The
    /// display state (snapshot, phase, source) is left as-is for the caller's
    /// next foreground scan or restore to reset.
    @discardableResult
    func detach() -> ScanSession? {
        guard let session = displayedSession else { return nil }
        displayedSession = nil
        return session
    }

    /// Records a complete snapshot into the recent-snapshot LRU without
    /// putting it on screen — a background scan's finished tree, so switching
    /// to that target returns it instantly. Partials are rejected.
    func insertRecentSnapshot(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete else { return }
        rememberRecentSnapshot(snapshot)
    }

    func stopScan(resetState: Bool = true) {
        displayedSession?.cancel()
        displayedSession = nil
        cancelExpansion()

        var metrics = scanMetrics
        metrics.isFinalizing = false
        scanMetrics = metrics

        if resetState {
            phase = snapshot == nil ? .idle : .displaying
        }
    }

    func clearScan() {
        stopScan(resetState: false)
        selectedTarget = nil
        snapshot = nil
        displaySource = .none
        scanMetrics = ScanMetrics()
        phase = .idle
    }

    func replaceCurrentSnapshot(_ snapshot: ScanSnapshot?) {
        self.snapshot = snapshot
        if snapshot == nil {
            displaySource = .none
            phase = .idle
        } else if !isScanning {
            displaySource = .restoredWithoutScan
            phase = .displaying
        }
    }

    // MARK: - In-memory recent snapshots

    /// The remembered snapshot for a target, if it was displayed recently
    /// enough to still be retained. Callers use it to skip the disk decode
    /// entirely when switching back to a location.
    func recentSnapshot(forTargetID targetID: String) -> ScanSnapshot? {
        recentSnapshotsByTargetID[targetID]
    }

    /// Drops a target's remembered snapshot. Must be called when the
    /// target's persisted scans are deleted — session memory must never
    /// resurrect a scan the user removed.
    func forgetRecentSnapshot(forTargetID targetID: String) {
        recentSnapshotsByTargetID.removeValue(forKey: targetID)
        recentSnapshotTargetIDs.removeAll { $0 == targetID }
    }

    func forgetAllRecentSnapshots() {
        recentSnapshotsByTargetID = [:]
        recentSnapshotTargetIDs = []
    }

    private func rememberRecentSnapshot(_ snapshot: ScanSnapshot) {
        let targetID = snapshot.target.id
        recentSnapshotsByTargetID[targetID] = snapshot
        recentSnapshotTargetIDs.removeAll { $0 == targetID }
        recentSnapshotTargetIDs.append(targetID)

        // Evict least-recently-displayed entries beyond the count cap or the
        // node budget, but always keep the newest — a single giant volume
        // must still be remembered.
        var totalNodes = recentSnapshotTargetIDs
            .compactMap { recentSnapshotsByTargetID[$0]?.treeStore.nodeCount }
            .reduce(0, +)
        while recentSnapshotTargetIDs.count > 1,
              recentSnapshotTargetIDs.count > Self.maxRecentSnapshots
              || totalNodes > Self.recentSnapshotNodeBudget {
            let evicted = recentSnapshotTargetIDs.removeFirst()
            totalNodes -= recentSnapshotsByTargetID.removeValue(forKey: evicted)?
                .treeStore.nodeCount ?? 0
        }
    }

    func restoreCompletedSnapshot(
        _ snapshot: ScanSnapshot,
        prepare: () -> Void = {}
    ) {
        guard snapshot.isComplete else { return }

        stopScan(resetState: false)
        prepare()

        FeltTiming.noteRestoreCompleted(snapshotID: snapshot.id)
        selectedTarget = snapshot.target
        scanErrorMessage = nil
        apply(snapshot: snapshot)
        displaySource = .restoredWithoutScan

        var metrics = ScanMetrics()
        metrics.recalculateProgress(isComplete: true)
        scanMetrics = metrics
        phase = .displaying
    }

    /// Scans an auto-summarized folder's or a package's real contents and
    /// splices them into the displayed tree, returning how the expansion
    /// ended. A newer expansion, a snapshot removal, or stopScan cancels the
    /// awaited work (the call then returns `.cancelled`).
    func expandNodeContents(
        _ node: FileNodeRecord,
        options: ScanOptions
    ) async -> ScanExpansionResult {
        guard node.isAutoSummarized || (node.isPackage && node.isDirectory) else { return .skipped }
        cancelExpansion()

        let expansionID = UUID()
        activeExpansionID = expansionID
        expandingNodeID = node.id

        let target = ScanTarget(url: node.url)
        let stream = scanService.scan(target: target, options: options)
        let task = Task { [weak self] in
            await self?.consumeExpansionStream(stream, node: node, expansionID: expansionID) ?? .cancelled
        }
        expandTask = task
        let result = await task.value
        if activeExpansionID == expansionID {
            activeExpansionID = nil
            expandingNodeID = nil
            expandTask = nil
        }
        return result
    }

    private func consumeExpansionStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        node: FileNodeRecord,
        expansionID: UUID
    ) async -> ScanExpansionResult {
        do {
            var expandedSnapshot: ScanSnapshot?
            for try await event in stream {
                guard activeExpansionID == expansionID else { return .cancelled }
                if case .finished(let snapshot) = event {
                    expandedSnapshot = snapshot
                }
            }

            try Task.checkCancellation()
            guard activeExpansionID == expansionID, let expandedSnapshot else {
                return .cancelled
            }

            let replacementRootID = try await replaceNodeInTree(
                node,
                with: expandedSnapshot,
                expansionID: expansionID
            )
            guard activeExpansionID == expansionID else { return .cancelled }
            guard let replacementRootID else { return .skipped }
            return .expanded(replacementRootID: replacementRootID)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: "Failed to scan '\(node.name)': \(error.localizedDescription)")
        }
    }

    private func apply(snapshot: ScanSnapshot) {
        self.snapshot = snapshot
    }

    private func cancelExpansion() {
        activeExpansionID = nil
        expandingNodeID = nil
        expandTask?.cancel()
        expandTask = nil
    }

    @discardableResult
    private func replaceNodeInTree(
        _ oldNode: FileNodeRecord,
        with expandedSnapshot: ScanSnapshot,
        expansionID: UUID
    ) async throws -> FileNodeRecord.ID? {
        guard let currentSnapshot = snapshot else { return nil }
        let currentSnapshotID = currentSnapshot.id
        guard let updatedSnapshot = try await snapshotTransformService.replacingNode(
            in: currentSnapshot,
            id: oldNode.id,
            with: expandedSnapshot.treeStore,
            additionalWarnings: expandedSnapshot.scanWarnings
        ) else { return nil }
        try Task.checkCancellation()
        guard activeExpansionID == expansionID,
              snapshot?.id == currentSnapshotID else {
            return nil
        }

        snapshot = updatedSnapshot
        return expandedSnapshot.root.id
    }
}
