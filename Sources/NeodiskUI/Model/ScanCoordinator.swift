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

    /// The baseline is the target's last complete snapshot, so an incremental service can re-enumerate only
    /// what changed; nil means scan from scratch.
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

/// Where the displayed tree comes from and how live scan events treat it.
enum DisplaySource: Equatable, Sendable {
    /// Nothing on screen.
    case none
    /// Live scan results stream to the screen (partials while scanning,
    /// then the finished snapshot).
    case liveStreaming
    /// A complete stale map stands in while a refresh runs: partials are suppressed and `.finished` swaps in.
    /// `scanDate` is the stand-in's finish date, nil until it has decoded and displayed.
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
            // Every complete snapshot that reaches the screen becomes the instant-display copy.
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

    /// Tracked (not `@ObservationIgnored`) so `progress` readers re-bind when the displayed session swaps;
    /// each session owns its own `ScanProgressState`.
    private(set) var displayedSession: ScanSession?
    @ObservationIgnored private let idleProgress: ScanProgressState

    /// The metrics of the scan on screen — the displayed session's own
    /// progress, falling back to the idle instance between scans.
    var progress: ScanProgressState {
        displayedSession?.progress ?? idleProgress
    }

    /// Shared with the sessions ScanSessionModel constructs, so every session uses this coordinator's service.
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

    /// Recently displayed complete snapshots, so switching back skips the cache decode. Bounded by a total
    /// node budget; the displayed one is usually among them, so only the tail costs memory.
    @ObservationIgnored private var recentSnapshotsByTargetID: [String: ScanSnapshot] = [:]
    /// Least-recently-displayed first.
    @ObservationIgnored private var recentSnapshotTargetIDs: [String] = []
    private static let maxRecentSnapshots = 4
    private static let recentSnapshotNodeBudget = 4_000_000

    @ObservationIgnored private var expandTask: Task<ScanExpansionResult, Never>?
    @ObservationIgnored private var activeExpansionID: UUID?
    /// Fires after every displayed-snapshot change, partials included.
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

    /// How live events treat a newly attached session, so a re-attached background scan resumes as it left.
    enum AttachMode: Equatable {
        /// A cold scan streaming to the screen: partials display as they grow.
        case live
        /// A refresh behind a complete stand-in: partials are suppressed until the fresh finish.
        case refreshBehindCache(scanDate: Date?)
    }

    /// The single path that puts a scan on screen, fresh or re-attached. The caller has already reset per-scan
    /// UI state and wired hooks; whatever was displayed is cancelled unless a demote detached it first.
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

        // Rebinding `progress` keeps a re-attached background scan's bar where it left off.
        displayedSession = session
    }

    /// Ignored once the session was demoted or the display moved on; the snapshot stays on
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

    /// A cached snapshot decodes for display and no scan runs until the user asks for one.
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

    /// Ignored when the user moved on (another target, or a scan started) while the decode ran.
    func completeSnapshotRestore(_ snapshot: ScanSnapshot) {
        guard phase == .restoring,
              snapshot.isComplete,
              selectedTarget?.id == snapshot.target.id else {
            return
        }
        restoreCompletedSnapshot(snapshot)
    }

    /// For when the awaited stand-in turned out unreadable; only while that session is still on screen.
    func abandonRefreshBaselineIfAttached(_ session: ScanSession) {
        guard session === displayedSession,
              isScanning,
              case .cachedWhileRefreshing = displaySource,
              snapshot?.isComplete != true else {
            return
        }
        displaySource = .liveStreaming
    }

    /// Self-gates on the displayed session so a background scan's partials reach nothing.
    func showDisplayedPartial(from session: ScanSession) {
        guard session === displayedSession, !suppressesPartialEvents else { return }
        guard let partial = session.latestSnapshot, !partial.isComplete else { return }
        let since = ScanProfile.now()
        snapshot = partial
        ScanProfile.addNamed("app.applyPartial", since: since)
    }

    /// Self-gates on the displayed session; a background scan's completion is the session model's concern.
    func settleDisplayedCompletion(from session: ScanSession) {
        guard session === displayedSession else { return }

        switch session.state {
        case .finished:
            guard let finished = session.latestSnapshot, finished.isComplete else { return }
            FeltTiming.noteEngineFinished(snapshotID: finished.id)
            let since = ScanProfile.now()
            apply(snapshot: finished)
            ScanProfile.addNamed("app.applyFinal", since: since)
            displaySource = .liveStreaming
            phase = .displaying
        case .failed(let message):
            displaySource = .none
            phase = .failed
            scanErrorMessage = message
        case .cancelled:
            phase = snapshot == nil ? .idle : .displaying
        case .running:
            return
        }
        idleProgress.metrics = session.progress.metrics
        displayedSession = nil
    }

    /// Releases the displayed session without cancelling it, so it keeps running as a background scan.
    /// The display state is left for the next foreground scan or restore to reset.
    @discardableResult
    func detach() -> ScanSession? {
        guard let session = displayedSession else { return nil }
        displayedSession = nil
        return session
    }

    /// For a background scan's finished tree, so switching to that target returns it instantly.
    func insertRecentSnapshot(_ snapshot: ScanSnapshot) {
        guard snapshot.isComplete else { return }
        rememberRecentSnapshot(snapshot)
    }

    func stopScan(resetState: Bool = true) {
        if let session = displayedSession {
            idleProgress.metrics = session.progress.metrics
            session.cancel()
        }
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

    func recentSnapshot(forTargetID targetID: String) -> ScanSnapshot? {
        recentSnapshotsByTargetID[targetID]
    }

    /// Must be called when the target's persisted scans are deleted, so memory never resurrects them.
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

        // Always keep the newest: a single giant volume must still be remembered.
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

    /// Scans a summarized folder's or package's real contents and splices them in. A newer expansion,
    /// a snapshot removal or stopScan cancels it (returns `.cancelled`).
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
