//
//  AtomicDirectorySummaryPool.swift
//  Neodisk
//

import Foundation

/// Thrown by a job's cancellation token once the job is cancelled, so a worker
/// abandons the item it is processing promptly instead of finishing a walk whose
/// result will be discarded.
nonisolated struct AtomicSummaryJobCancelled: Error {}

nonisolated private final class AtomicSummaryJobToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw AtomicSummaryJobCancelled()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }
}

/// One package/atomic-directory summary submitted to the pool.
nonisolated struct AtomicSummaryPoolRequest: @unchecked Sendable {
    let url: URL
    let includeHiddenFiles: Bool
    let treatPackagesAsDirectories: Bool
    let ownerNodeID: String
    let exclusionMatcher: ScanExclusionMatcher
    let metadataLoader: ScanMetadataLoader
    let bulkEnumerationEnabled: Bool
    let cancellationCheck: CancellationCheck
}

/// Publishes throttled current-path heartbeats while pooled jobs (and the
/// atomic probe running alongside them) work. The base metrics come from the
/// scan loop, which recalculates them monotonically, so heartbeats never regress
/// the progress fraction the way a stale per-job snapshot could.
nonisolated private final class AtomicSummaryProgressHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private let emissionInterval: TimeInterval
    private var base = ScanMetrics()
    private var hasBase = false
    private var lastEmission = Date.distantPast

    init(
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionInterval: TimeInterval
    ) {
        self.continuation = continuation
        self.emissionInterval = max(emissionInterval, 0)
    }

    func recordBase(_ metrics: ScanMetrics) {
        lock.lock()
        base = metrics
        hasBase = true
        lock.unlock()
    }

    func emit(currentPath: String) {
        lock.lock()
        guard hasBase else {
            lock.unlock()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastEmission) >= emissionInterval else {
            lock.unlock()
            return
        }
        lastEmission = now
        var snapshot = base
        snapshot.currentPath = currentPath
        lock.unlock()
        // AsyncThrowingStream continuations are thread-safe.
        continuation.yield(.progress(snapshot))
    }
}

/// A scan-scoped worker pool shared by every package and atomic-summary job.
///
/// The pool owns exactly `workerLimit` workers. Each job keeps its own work
/// stack (one item = one directory level) and partial summary, while runnable
/// jobs are selected round-robin so a deep package cannot starve newly
/// discovered small bundles. Created once per `ScanTraversal.run()` and torn
/// down when it finishes (drain) or errors/cancels (`cancelAndFinish`).
nonisolated final class AtomicDirectorySummaryPool: @unchecked Sendable {
    private struct Lease: @unchecked Sendable {
        let jobID: Int
        let leaseID: Int
        let token: AtomicSummaryJobToken
        let item: AtomicSummaryWorkItem
        let request: AtomicSummaryPoolRequest
    }

    private final class Job {
        let id: Int
        let request: AtomicSummaryPoolRequest
        let continuation: CheckedContinuation<AtomicDirectorySummary?, Error>
        let token = AtomicSummaryJobToken()
        var partial: AtomicDirectorySummaryPartial
        var pendingItems: [AtomicSummaryWorkItem]
        var activeItemCount = 0
        var isRunnable = false

        init(
            id: Int,
            request: AtomicSummaryPoolRequest,
            continuation: CheckedContinuation<AtomicDirectorySummary?, Error>,
            partial: AtomicDirectorySummaryPartial,
            pendingItems: [AtomicSummaryWorkItem]
        ) {
            self.id = id
            self.request = request
            self.continuation = continuation
            self.partial = partial
            self.pendingItems = pendingItems
        }
    }

    private enum CompletionAction {
        case success(CheckedContinuation<AtomicDirectorySummary?, Error>, AtomicDirectorySummary?)
        case failure(CheckedContinuation<AtomicDirectorySummary?, Error>, Error)

        func resume() {
            switch self {
            case .success(let continuation, let summary):
                continuation.resume(returning: summary)
            case .failure(let continuation, let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private let condition = NSCondition()
    private let workerLimit: Int
    private let heartbeat: AtomicSummaryProgressHeartbeat
    private var nextJobID = 0
    private var nextLeaseID = 0
    private var jobs: [Int: Job] = [:]
    private var cancelledJobIDs: Set<Int> = []
    private var runnableJobIDs: [Int] = []
    private var waitingWorkers: [CheckedContinuation<Lease?, Never>] = []
    private var workerTasks: [Task<Void, Never>] = []
    private var hasStarted = false
    private var acceptsJobs = true
    private var shutdownError: Error?

    init(
        workerLimit: Int,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        progressEmissionInterval: TimeInterval = 0.15
    ) {
        self.workerLimit = max(1, workerLimit)
        self.heartbeat = AtomicSummaryProgressHeartbeat(
            continuation: continuation,
            emissionInterval: progressEmissionInterval
        )
    }

    /// Feeds the scan loop's latest recalculated metrics to the heartbeat so
    /// its current-path emissions carry a fresh, non-regressing progress state.
    func recordProgressBase(_ metrics: ScanMetrics) {
        heartbeat.recordBase(metrics)
    }

    /// Publishes a throttled current-path heartbeat. Used by the atomic probe,
    /// which runs off the pool but alongside pooled summaries.
    func emit(currentPath: String) {
        heartbeat.emit(currentPath: currentPath)
    }

    /// Starts the fixed worker set. Calling this more than once has no effect.
    func start() {
        condition.lock()
        guard !hasStarted else {
            condition.unlock()
            return
        }
        hasStarted = true
        workerTasks = (0..<workerLimit).map { _ in
            Task { await self.workerLoop() }
        }
        condition.unlock()
    }

    /// Stops accepting jobs, drains registered jobs, and awaits every worker.
    func finish() async {
        let tasks = finishAcceptingJobs()
        for task in tasks {
            await task.value
        }
    }

    /// Fails all registered jobs, wakes workers, and awaits their termination.
    func cancelAndFinish(with error: Error) async {
        let tasks = cancelAll(with: error)
        for task in tasks {
            await task.value
        }
    }

    func summarize(_ request: AtomicSummaryPoolRequest) async throws -> AtomicDirectorySummary? {
        start()
        try request.cancellationCheck()
        let jobID = reserveJobID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerJob(id: jobID, request: request, continuation: continuation)
            }
        } onCancel: {
            self.cancelJob(id: jobID, error: CancellationError())
        }
    }

    private func reserveJobID() -> Int {
        condition.lock()
        let id = nextJobID
        nextJobID += 1
        condition.unlock()
        return id
    }

    private func registerJob(
        id: Int,
        request: AtomicSummaryPoolRequest,
        continuation: CheckedContinuation<AtomicDirectorySummary?, Error>
    ) {
        let partial = makeInitialPartial(for: request)
        let initialItems = [
            AtomicSummaryWorkItem(
                url: request.url,
                treatPackagesAsDirectories: request.treatPackagesAsDirectories,
                ownerNodeID: request.ownerNodeID
            )
        ]

        var rejection: Error?
        var completion: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if cancelledJobIDs.remove(id) != nil {
            rejection = CancellationError()
        } else if let shutdownError {
            rejection = shutdownError
        } else if !acceptsJobs {
            rejection = CancellationError()
        } else {
            let job = Job(
                id: id,
                request: request,
                continuation: continuation,
                partial: partial,
                pendingItems: initialItems
            )
            jobs[id] = job
            makeRunnableLocked(job)
            completion = completeJobIfNeededLocked(job)
            wakeups = wakeWorkersLocked()
        }
        condition.unlock()
        resumeWorkerWakeups(wakeups)

        if let rejection {
            continuation.resume(throwing: rejection)
        } else {
            completion?.resume()
        }
    }

    private func makeInitialPartial(for request: AtomicSummaryPoolRequest) -> AtomicDirectorySummaryPartial {
        var partial = AtomicDirectorySummaryPartial()
        do {
            let values = try request.url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
            partial.updateAccessibility(values.isReadable ?? true)
        } catch {
            partial.recordWarning(for: request.url, error: error)
        }
        return partial
    }

    private func workerLoop() async {
        // Per-worker visit throttle: the shared heartbeat takes a lock per
        // emit, so only every 64th visited child reaches it (matching the
        // pre-pool reporters), not every file of every worker.
        var visitCount = 0
        while let lease = await takeWork() {
            do {
                var result = AtomicSummaryWorkResult(
                    partial: AtomicDirectorySummaryPartial(),
                    pendingItems: []
                )
                let sink = AtomicSummaryLevelSink(
                    onVisit: { url in
                        visitCount += 1
                        if visitCount == 1 || visitCount.isMultiple(of: 64) {
                            self.heartbeat.emit(currentPath: url.path)
                        }
                    },
                    onAccessibility: { result.partial.updateAccessibility($0) },
                    onWarning: { result.partial.recordWarning(for: $0, error: $1) },
                    onFile: { result.partial.accumulateFile($0, url: $1, ownerNodeID: lease.item.ownerNodeID) },
                    onSubdirectory: { result.pendingItems.append($0) }
                )
                try AtomicDirectorySummarizer.processDirectoryLevel(
                    lease.item,
                    includeHiddenFiles: lease.request.includeHiddenFiles,
                    exclusionMatcher: lease.request.exclusionMatcher,
                    metadataLoader: lease.request.metadataLoader,
                    bulkEnumerationEnabled: lease.request.bulkEnumerationEnabled,
                    cancellationCheck: {
                        try lease.request.cancellationCheck()
                        try lease.token.check()
                    },
                    sink: sink
                )
                complete(lease, result: result)
            } catch is AtomicSummaryJobCancelled {
                discard(lease)
            } catch {
                fail(lease, error: error)
            }
        }
    }

    private func takeWork() async -> Lease? {
        await withCheckedContinuation { continuation in
            condition.lock()
            if let lease = nextLeaseLocked() {
                condition.unlock()
                continuation.resume(returning: lease)
            } else if workersShouldStopLocked {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                waitingWorkers.append(continuation)
                condition.unlock()
            }
        }
    }

    private func complete(_ lease: Lease, result: AtomicSummaryWorkResult) {
        var action: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID] {
            job.activeItemCount = max(job.activeItemCount - 1, 0)
            job.partial.merge(result.partial)
            job.pendingItems.append(contentsOf: result.pendingItems)
            makeRunnableLocked(job)
            action = completeJobIfNeededLocked(job)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        action?.resume()
    }

    private func discard(_ lease: Lease) {
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID] {
            job.activeItemCount = max(job.activeItemCount - 1, 0)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
    }

    private func fail(_ lease: Lease, error: Error) {
        var action: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs[lease.jobID] {
            job.token.cancel()
            jobs.removeValue(forKey: job.id)
            runnableJobIDs.removeAll { $0 == job.id }
            action = .failure(job.continuation, error)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        action?.resume()
    }

    private func cancelJob(id: Int, error: Error) {
        var action: CompletionAction?
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        condition.lock()
        if let job = jobs.removeValue(forKey: id) {
            job.token.cancel()
            runnableJobIDs.removeAll { $0 == id }
            action = .failure(job.continuation, error)
        } else if acceptsJobs, shutdownError == nil {
            // Cancellation can race registration while the submitter prepares
            // root metadata. Retain a tombstone so a late registration cannot
            // create orphaned work after its awaiting task has been cancelled.
            cancelledJobIDs.insert(id)
        }
        wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        action?.resume()
    }

    private func finishAcceptingJobs() -> [Task<Void, Never>] {
        condition.lock()
        acceptsJobs = false
        let tasks = workerTasks
        let wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        return tasks
    }

    private func cancelAll(with error: Error) -> [Task<Void, Never>] {
        var actions: [CompletionAction] = []
        condition.lock()
        shutdownError = error
        acceptsJobs = false
        for job in jobs.values {
            job.token.cancel()
            actions.append(.failure(job.continuation, error))
        }
        jobs.removeAll()
        cancelledJobIDs.removeAll()
        runnableJobIDs.removeAll()
        let tasks = workerTasks
        let wakeups = wakeWorkersLocked()
        condition.unlock()
        resumeWorkerWakeups(wakeups)
        actions.forEach { $0.resume() }
        return tasks
    }

    private func makeRunnableLocked(_ job: Job) {
        guard !job.pendingItems.isEmpty, !job.isRunnable else { return }
        job.isRunnable = true
        runnableJobIDs.append(job.id)
    }

    private func completeJobIfNeededLocked(_ job: Job) -> CompletionAction? {
        guard job.pendingItems.isEmpty, job.activeItemCount == 0 else {
            return nil
        }
        jobs.removeValue(forKey: job.id)
        runnableJobIDs.removeAll { $0 == job.id }
        return .success(job.continuation, job.partial.makeSummary())
    }

    /// Round-robins one directory level off the front-most runnable job (FIFO of
    /// job IDs), taking a DFS item (`removeLast`) within that job and re-appending
    /// the job to the back if it still has work. This is what stops a deep package
    /// from starving small sibling bundles.
    private func nextLeaseLocked() -> Lease? {
        while let jobID = runnableJobIDs.first {
            runnableJobIDs.removeFirst()
            guard let job = jobs[jobID], !job.pendingItems.isEmpty else {
                continue
            }
            job.isRunnable = false
            let item = job.pendingItems.removeLast()
            let leaseID = nextLeaseID
            nextLeaseID += 1
            job.activeItemCount += 1
            makeRunnableLocked(job)
            return Lease(
                jobID: job.id,
                leaseID: leaseID,
                token: job.token,
                item: item,
                request: job.request
            )
        }
        return nil
    }

    private var workersShouldStopLocked: Bool {
        shutdownError != nil || (!acceptsJobs && jobs.isEmpty)
    }

    private func wakeWorkersLocked() -> [(CheckedContinuation<Lease?, Never>, Lease?)] {
        var wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)] = []
        while !waitingWorkers.isEmpty {
            if let lease = nextLeaseLocked() {
                wakeups.append((waitingWorkers.removeFirst(), lease))
            } else if workersShouldStopLocked {
                while !waitingWorkers.isEmpty {
                    wakeups.append((waitingWorkers.removeFirst(), nil))
                }
                break
            } else {
                break
            }
        }
        return wakeups
    }

    private func resumeWorkerWakeups(
        _ wakeups: [(CheckedContinuation<Lease?, Never>, Lease?)]
    ) {
        for (continuation, lease) in wakeups {
            continuation.resume(returning: lease)
        }
    }
}
