import Foundation
import Observation
import NeodiskKit

/// The coordinator decides whether a session's updates reach the screen; the session always records them.
@MainActor
@Observable
final class ScanSession: Identifiable {
    enum Kind: Equatable {
        case fresh
        case refresh
    }

    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let target: ScanTarget
    let options: ScanOptions
    let kind: Kind
    let startedAt: Date
    let progress: ScanProgressState

    /// A display contract independent of `kind`. Flips to false if a refresh's decode misses and it reverts
    /// to streaming, so re-attaching a demoted scan resumes its display exactly as it left.
    var showsStandInWhileScanning: Bool

    /// Held on the session so a late decode lands on its own scan, and a re-attach redisplays it,
    /// even if the display moved to another target meanwhile.
    var refreshBaseline: ScanSnapshot?

    private(set) var state: State = .running
    /// The latest partial while running, the final snapshot on finish. Recorded
    /// unconditionally — even when the coordinator suppresses it from display.
    private(set) var latestSnapshot: ScanSnapshot?

    /// Fires after `latestSnapshot` changes (each partial, and the final).
    var onSnapshotUpdate: ((ScanSession) -> Void)?
    /// Not fired by a coordinator-driven `cancel()`; the coordinator already knows.
    var onCompletion: ((ScanSession) -> Void)?

    @ObservationIgnored private let scanService: any ScanEventStreaming
    @ObservationIgnored private var baselineProvider: (@Sendable () async -> ScanSnapshot?)?
    @ObservationIgnored private let progressThrottleDuration: Duration
    @ObservationIgnored private let progressClock = ContinuousClock()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var progressPublishTask: Task<Void, Never>?
    @ObservationIgnored private var pendingProgressMetrics: ScanMetrics?
    @ObservationIgnored private var lastProgressPublishTime: ContinuousClock.Instant?

    init(
        target: ScanTarget,
        options: ScanOptions,
        kind: Kind,
        service: any ScanEventStreaming,
        baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil,
        showsStandInWhileScanning: Bool = false,
        refreshBaseline: ScanSnapshot? = nil,
        progress: ScanProgressState,
        progressThrottleDuration: Duration
    ) {
        self.target = target
        self.options = options
        self.kind = kind
        self.scanService = service
        self.baselineProvider = baselineProvider
        self.showsStandInWhileScanning = showsStandInWhileScanning
        self.refreshBaseline = refreshBaseline
        self.progress = progress
        self.progressThrottleDuration = progressThrottleDuration
        self.startedAt = Date()
    }

    private var scanMetrics: ScanMetrics {
        get { progress.metrics }
        set { progress.metrics = newValue }
    }

    func start() {
        let stream = baselineProvider.map { provider in
            scanService.rescan(target: target, options: options, baselineProvider: provider)
        } ?? scanService.scan(target: target, options: options)
        baselineProvider = nil
        scanTask = Task { [weak self] in
            await self?.consume(stream)
        }
    }

    /// Doesn't fire `onCompletion`; late events are ignored because the state is no longer `.running`.
    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        scanTask?.cancel()
        releaseScanInputs()
        resetProgressThrottling()
    }

    private func releaseScanInputs() {
        refreshBaseline = nil
        baselineProvider = nil
        scanTask = nil
    }

    // MARK: - Stream consumption

    private func consume(_ stream: AsyncThrowingStream<ScanProgressEvent, Error>) async {
        do {
            for try await event in stream {
                guard state == .running else { return }
                handle(event)
                guard state == .running else { return }
            }
        } catch is CancellationError {
            finishCancelled()
            return
        } catch {
            finishFailed(error)
            return
        }
        finishEndedWithoutSnapshot()
    }

    private func handle(_ event: ScanProgressEvent) {
        switch event {
        case .progress(let metrics):
            handleProgress(metrics)
        case .warning:
            break
        case .partial(let store):
            recordPartialTree(store)
        case .finished(let snapshot):
            finishSucceeded(with: snapshot)
        }
    }

    /// Recorded even while display is suppressed: the coordinator gates the screen, not this class.
    private func recordPartialTree(_ store: FileTreeStore) {
        latestSnapshot = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: startedAt,
            finishedAt: nil,
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: false
        )
        onSnapshotUpdate?(self)
    }

    private func finishSucceeded(with snapshot: ScanSnapshot) {
        flushPendingProgress()

        var completedMetrics = scanMetrics
        completedMetrics.recalculateProgress(isComplete: true)
        publishProgress(completedMetrics)

        latestSnapshot = snapshot
        state = .finished
        let stats = snapshot.aggregateStats
        DiagnosticLog.scan.info(
            "scan of \(target.id) finished: \(stats.fileCount) files, "
            + "\(snapshot.treeStore.nodeCount) nodes, \(snapshot.scanWarnings.count) warnings in "
            + "\(Date().timeIntervalSince(startedAt).formatted(.number.precision(.fractionLength(2))))s; "
            + MemoryFootprint.summary()
        )
        releaseScanInputs()
        onCompletion?(self)
    }

    private func finishFailed(_ error: Error) {
        guard state == .running else { return }
        resetProgressThrottling()
        DiagnosticLog.scan.error("scan of \(target.id) failed: \(error)")
        state = .failed(error.localizedDescription)
        releaseScanInputs()
        onCompletion?(self)
    }

    private func finishCancelled() {
        guard state == .running else { return }
        resetProgressThrottling()
        state = .cancelled
        releaseScanInputs()
        onCompletion?(self)
    }

    /// The stream closed without a final snapshot while still running (a
    /// defensive path). The coordinator settles the phase from what is shown.
    private func finishEndedWithoutSnapshot() {
        guard state == .running else { return }
        resetProgressThrottling()
        state = .cancelled
        releaseScanInputs()
        onCompletion?(self)
    }

    // MARK: - Progress throttling

    private func handleProgress(_ metrics: ScanMetrics) {
        if shouldPublishProgressImmediately {
            publishProgress(metrics)
            return
        }

        pendingProgressMetrics = metrics
        schedulePendingProgressPublish()
    }

    private var shouldPublishProgressImmediately: Bool {
        guard progressThrottleDuration > .zero else { return true }
        guard let lastProgressPublishTime else { return true }

        return lastProgressPublishTime.duration(to: progressClock.now) >= progressThrottleDuration
    }

    private func schedulePendingProgressPublish() {
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

            self?.publishPendingProgress()
        }
    }

    private func publishPendingProgress() {
        guard state == .running else { return }
        progressPublishTask = nil
        guard let pendingProgressMetrics else { return }
        publishProgress(pendingProgressMetrics)
    }

    private func publishProgress(_ metrics: ScanMetrics) {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressMetrics = nil
        lastProgressPublishTime = progressClock.now
        var monotonicMetrics = metrics
        if state == .running {
            // Final hard-link/clone accounting can come in below the live estimate, and the strip is a
            // discovery counter, so it must never count down.
            monotonicMetrics.filesVisited = max(
                monotonicMetrics.filesVisited,
                scanMetrics.filesVisited
            )
            monotonicMetrics.bytesDiscovered = max(
                monotonicMetrics.bytesDiscovered,
                scanMetrics.bytesDiscovered
            )
        }
        scanMetrics = monotonicMetrics
    }

    private func flushPendingProgress() {
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
}
