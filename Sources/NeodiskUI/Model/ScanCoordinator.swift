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
    private(set) var completedScanSnapshot: ScanSnapshot?
    private(set) var scanErrorMessage: String?
    private(set) var expandingNodeID: FileNodeRecord.ID?
    /// See DisplaySource — all transitions live in this class.
    private(set) var displaySource: DisplaySource = .none
    let progress: ScanProgressState

    @ObservationIgnored private let scanService: any ScanEventStreaming
    @ObservationIgnored private let snapshotTransformService: any ScanSnapshotTransforming
    @ObservationIgnored private let progressThrottleDuration: Duration
    @ObservationIgnored private let progressClock = ContinuousClock()

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

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var expandTask: Task<ScanExpansionResult, Never>?
    @ObservationIgnored private var progressPublishTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID: UUID?
    @ObservationIgnored private var activeScanStartDate: Date?
    @ObservationIgnored private var activeExpansionID: UUID?
    @ObservationIgnored private var pendingProgressMetrics: ScanMetrics?
    @ObservationIgnored private var lastProgressPublishTime: ContinuousClock.Instant?
    @ObservationIgnored var onScanFinished: ((ScanSnapshot) -> Void)?
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
        self.progress = progress
    }

    /// Always the displayed snapshot's tree — the two were separate
    /// published properties set together at every site.
    var fileTreeStore: FileTreeStore? {
        snapshot?.treeStore
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

    var canStopScan: Bool {
        isScanning
    }

    var snapshotSource: ScanSnapshotSource {
        snapshot?.source ?? .live
    }

    func startScan(
        _ target: ScanTarget,
        options: ScanOptions,
        prepare: () -> Void = {}
    ) {
        beginScan(target, options: options, retainedSnapshot: nil, prepare: prepare)
    }

    /// Starts a scan that refreshes an already-known result: the current
    /// snapshot stays on screen when it is a complete scan of the same
    /// target (otherwise the caller feeds one in via
    /// `displayCachedSnapshot`), and `.partial` events are suppressed until
    /// the fresh `.finished` snapshot replaces it.
    ///
    /// `baselineProvider` hands the scan service the target's last complete
    /// snapshot so it can rescan incrementally; when nil, the displayed
    /// same-target snapshot (if complete) serves as the baseline.
    func startRefreshScan(
        _ target: ScanTarget,
        options: ScanOptions,
        baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil,
        prepare: () -> Void = {}
    ) {
        // Prefer what this session already holds: the displayed snapshot, or
        // a recently displayed one of the same target. Either keeps the map
        // on screen through the refresh with no cache decode, and doubles as
        // the incremental baseline (it IS the target's last complete scan).
        let retainedSnapshot = snapshot?.isComplete == true && snapshot?.target.id == target.id
            ? snapshot
            : recentSnapshot(forTargetID: target.id)
        let baselineProvider = retainedSnapshot.map { retained in
            { @Sendable in retained }
        } ?? baselineProvider
        beginScan(
            target,
            options: options,
            retainedSnapshot: retainedSnapshot,
            baselineProvider: baselineProvider,
            prepare: prepare
        )
        displaySource = .cachedWhileRefreshing(
            scanDate: retainedSnapshot.map { $0.finishedAt ?? $0.startedAt }
        )
    }

    /// Swaps a cached snapshot in as the displayed result while a refresh
    /// scan is still running. Ignored once the fresh scan has finished (or
    /// the user moved on to another target) so a slow decode can never
    /// clobber newer data.
    func displayCachedSnapshot(_ cached: ScanSnapshot) {
        guard cached.isComplete,
              isScanning,
              case .cachedWhileRefreshing = displaySource,
              selectedTarget?.id == cached.target.id,
              snapshot?.isComplete != true else {
            return
        }
        apply(snapshot: cached)
        completedScanSnapshot = cached
        displaySource = .cachedWhileRefreshing(scanDate: cached.finishedAt ?? cached.startedAt)
    }

    /// Enters the restore phase: a cached snapshot is decoding for display
    /// and no scan will run until the user asks for one. The detail view
    /// shows a lightweight loading state until `completeSnapshotRestore`
    /// swaps the decoded snapshot in.
    func beginSnapshotRestore(_ target: ScanTarget, prepare: () -> Void = {}) {
        stopScan(resetState: false)
        prepare()

        selectedTarget = target
        phase = .restoring
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        snapshot = nil
        completedScanSnapshot = nil
        displaySource = .none
        resetProgressThrottling()
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

    /// Reverts a refresh scan to normal live streaming when the cached
    /// snapshot it was waiting for turned out to be unreadable.
    func abandonCachedSnapshotDisplay(forTargetID targetID: String) {
        guard isScanning,
              case .cachedWhileRefreshing = displaySource,
              selectedTarget?.id == targetID,
              snapshot?.isComplete != true else {
            return
        }
        displaySource = .liveStreaming
    }

    private func beginScan(
        _ target: ScanTarget,
        options: ScanOptions,
        retainedSnapshot: ScanSnapshot?,
        baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil,
        prepare: () -> Void
    ) {
        stopScan(resetState: false)
        prepare()

        selectedTarget = target
        phase = .scanning
        scanErrorMessage = nil
        scanMetrics = ScanMetrics()
        snapshot = retainedSnapshot
        completedScanSnapshot = retainedSnapshot
        // startRefreshScan upgrades this to .cachedWhileRefreshing.
        displaySource = .liveStreaming
        resetProgressThrottling()

        let scanID = UUID()
        activeScanID = scanID
        activeScanStartDate = Date()
        let stream = baselineProvider.map { provider in
            scanService.rescan(target: target, options: options, baselineProvider: provider)
        } ?? scanService.scan(target: target, options: options)
        scanTask = Task { [weak self] in
            await self?.consumeScanStream(stream, scanID: scanID)
        }
    }

    func stopScan(resetState: Bool = true) {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        resetProgressThrottling()
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
        completedScanSnapshot = nil
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

        selectedTarget = snapshot.target
        scanErrorMessage = nil
        resetProgressThrottling()
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot.source.isPersistable ? snapshot : nil
        displaySource = .restoredWithoutScan

        var metrics = ScanMetrics()
        metrics.recalculateProgress(isComplete: true)
        scanMetrics = metrics
        phase = .displaying
    }

    @discardableResult
    func removeNodeFromCurrentSnapshot(id nodeID: FileNodeRecord.ID) async -> Bool {
        guard let currentSnapshot = snapshot else { return false }
        let currentSnapshotID = currentSnapshot.id

        if let expandingNodeID,
           currentSnapshot.treeStore.isAncestor(nodeID, of: expandingNodeID) {
            cancelExpansion()
        }

        do {
            guard let updatedSnapshot = try await snapshotTransformService.removingNode(
                in: currentSnapshot,
                id: nodeID
            ) else { return false }
            try Task.checkCancellation()
            guard snapshot?.id == currentSnapshotID else { return false }

            snapshot = updatedSnapshot
            completedScanSnapshot = nil
            if !isScanning {
                phase = .displaying
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            FileHandle.standardError.write(
                Data("Neodisk: removing \(nodeID) from the current snapshot failed: \(error)\n".utf8)
            )
            return false
        }
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

    private func consumeScanStream(
        _ stream: AsyncThrowingStream<ScanProgressEvent, Error>,
        scanID: UUID
    ) async {
        do {
            for try await event in stream {
                guard activeScanID == scanID else { break }
                handle(event, scanID: scanID)
            }
        } catch is CancellationError {
            completeCancelledScan(scanID: scanID)
            return
        } catch {
            failScan(error, scanID: scanID)
            return
        }

        completeScanIfActive(scanID: scanID)
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

    private func handle(_ event: ScanProgressEvent, scanID: UUID) {
        guard activeScanID == scanID else { return }

        switch event {
        case .progress(let metrics):
            handleProgress(metrics, scanID: scanID)
        case .warning:
            break
        case .partial(let store):
            handlePartialTree(store, scanID: scanID)
        case .finished(let snapshot):
            finishScan(with: snapshot, scanID: scanID)
        }
    }

    /// Publishes an in-progress tree so the UI can render a live, growing
    /// map. The phase stays `.scanning`; `finished` replaces this best-effort
    /// snapshot with exact data.
    private func handlePartialTree(_ store: FileTreeStore, scanID: UUID) {
        guard activeScanID == scanID, !suppressesPartialEvents, let selectedTarget else { return }


        snapshot = ScanSnapshot(
            target: selectedTarget,
            treeStore: store,
            startedAt: activeScanStartDate ?? Date(),
            finishedAt: nil,
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: false
        )
    }

    private func handleProgress(_ metrics: ScanMetrics, scanID: UUID) {
        guard activeScanID == scanID else { return }

        if shouldPublishProgressImmediately {
            publishProgress(metrics)
            return
        }

        pendingProgressMetrics = metrics
        schedulePendingProgressPublish(scanID: scanID)
    }

    private var shouldPublishProgressImmediately: Bool {
        guard progressThrottleDuration > .zero else { return true }
        guard let lastProgressPublishTime else { return true }

        return lastProgressPublishTime.duration(to: progressClock.now) >= progressThrottleDuration
    }

    private func schedulePendingProgressPublish(scanID: UUID) {
        guard progressPublishTask == nil else { return }

        let delay: Duration
        if let lastProgressPublishTime {
            let elapsed = lastProgressPublishTime.duration(to: progressClock.now)
            delay = elapsed >= progressThrottleDuration ? .zero : progressThrottleDuration - elapsed
        } else {
            delay = .zero
        }

        progressPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            self?.publishPendingProgress(scanID: scanID)
        }
    }

    private func publishPendingProgress(scanID: UUID) {
        guard activeScanID == scanID else { return }
        progressPublishTask = nil
        guard let pendingProgressMetrics else { return }
        publishProgress(pendingProgressMetrics)
    }

    private func publishProgress(_ metrics: ScanMetrics) {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = progressClock.now
        scanMetrics = metrics
    }

    private func finishScan(with snapshot: ScanSnapshot, scanID: UUID) {
        guard activeScanID == scanID else { return }

        flushPendingProgress(scanID: scanID)
        apply(snapshot: snapshot)
        completedScanSnapshot = snapshot
        displaySource = .liveStreaming

        var completedMetrics = scanMetrics
        completedMetrics.recalculateProgress(isComplete: true)
        publishProgress(completedMetrics)

        activeScanID = nil
        scanTask = nil
        phase = .displaying
        onScanFinished?(snapshot)
    }

    private func apply(snapshot: ScanSnapshot) {
        self.snapshot = snapshot
    }

    private func completeCancelledScan(scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        if snapshot == nil {
            phase = .idle
        }
        activeScanID = nil
        scanTask = nil
    }

    private func failScan(_ error: Error, scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        displaySource = .none
        phase = .failed
        scanErrorMessage = error.localizedDescription
        activeScanID = nil
        scanTask = nil
    }

    private func completeScanIfActive(scanID: UUID) {
        guard activeScanID == scanID else { return }

        resetProgressThrottling()
        phase = snapshot == nil ? .idle : .displaying
        activeScanID = nil
        scanTask = nil
    }

    private func flushPendingProgress(scanID: UUID) {
        guard activeScanID == scanID else { return }
        progressPublishTask?.cancel()
        progressPublishTask = nil

        if let pendingProgressMetrics {
            publishProgress(pendingProgressMetrics)
        }
    }

    private func resetProgressThrottling() {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = nil
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
