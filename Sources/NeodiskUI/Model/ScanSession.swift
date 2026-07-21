//
//  ScanSession.swift
//  Neodisk
//

import Foundation
import Observation
import NeodiskKit

/// Owns one scan's stream consumption and progress accounting: it runs the
/// scan task, throttles progress metrics into its `ScanProgressState`, and
/// keeps the latest partial (and the final) tree in `latestSnapshot`. The
/// coordinator decides whether a session's updates reach the screen — the
/// session always records them.
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

    /// Whether this session's display stands a complete snapshot in while the
    /// scan runs and suppresses partials (a refresh), rather than streaming the
    /// growing map (a cold scan). A display contract, independent of `kind` (a
    /// refresh awaiting its decode streams no baseline yet still suppresses).
    /// Starts true for a refresh but flips to false if the decode misses and
    /// the refresh reverts to live streaming, so re-attaching a demoted
    /// background scan resumes its display exactly as it left the screen.
    var showsStandInWhileScanning: Bool

    /// For a refresh, the complete stand-in shown while the scan runs — the
    /// retained in-memory snapshot, or the cache decode once it lands. Held on
    /// the session (not the coordinator) so a late decode lands on the scan it
    /// belongs to, and a demote/re-attach redisplays it, even if the display
    /// moved to another target in between.
    var refreshBaseline: ScanSnapshot?

    private(set) var state: State = .running
    /// The latest partial while running, the final snapshot on finish. Recorded
    /// unconditionally — even when the coordinator suppresses it from display.
    private(set) var latestSnapshot: ScanSnapshot?

    /// Fires after `latestSnapshot` changes (each partial, and the final).
    var onSnapshotUpdate: ((ScanSession) -> Void)?
    /// Fires once the session reaches a terminal state the coordinator acts on
    /// (`finished`, `failed`; the display-ending `cancelled` of a stream that
    /// closed without a final snapshot). A coordinator-driven `cancel()` does
    /// not fire it — the coordinator already knows.
    var onCompletion: ((ScanSession) -> Void)?

    @ObservationIgnored private let scanService: any ScanEventStreaming
    @ObservationIgnored private let baselineProvider: (@Sendable () async -> ScanSnapshot?)?
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
        scanTask = Task { [weak self] in
            await self?.consume(stream)
        }
    }

    /// Coordinator-initiated cancellation: stops the task and resets throttling
    /// without firing `onCompletion`. Late stream events are ignored because
    /// the state is no longer `.running`.
    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        scanTask?.cancel()
        scanTask = nil
        resetProgressThrottling()
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

    /// Records an in-progress tree so the coordinator can render a live,
    /// growing map. Recorded even while display is suppressed — the coordinator
    /// gates the screen, not this class.
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
        onCompletion?(self)
    }

    private func finishFailed(_ error: Error) {
        guard state == .running else { return }
        resetProgressThrottling()
        state = .failed(error.localizedDescription)
        onCompletion?(self)
    }

    private func finishCancelled() {
        guard state == .running else { return }
        resetProgressThrottling()
        state = .cancelled
    }

    /// The stream closed without a final snapshot while still running (a
    /// defensive path). The coordinator settles the phase from what is shown.
    private func finishEndedWithoutSnapshot() {
        guard state == .running else { return }
        resetProgressThrottling()
        state = .cancelled
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
            // Progress comes from the traversal coordinator and pooled summary
            // workers. Even with engine-side serialization, exact final
            // hard-link/clone accounting may be lower than the live estimate.
            // The strip is a discovery counter, so it must never count down.
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
