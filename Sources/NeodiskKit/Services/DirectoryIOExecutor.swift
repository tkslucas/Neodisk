//
//  DirectoryIOExecutor.swift
//  Neodisk
//
//  Blocking directory syscalls run on bounded, dedicated threads instead of
//  occupying Swift's cooperative executor. The threads share one queue, so
//  whichever is idle takes the next directory: a slow listing (a cache folder
//  with tens of thousands of entries) holds one thread, never the work queued
//  behind it. Each thread owns one reusable getattrlistbulk context.
//

import Dispatch
import Foundation

nonisolated final class DirectoryIOExecutor: @unchecked Sendable {
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func check() throws {
            lock.lock()
            let cancelled = isCancelled
            lock.unlock()
            if cancelled {
                throw CancellationError()
            }
        }
    }

    /// The queue and its threads. Threads hold this, not the executor, so the
    /// executor's deinit can tell them to exit once the queue drains.
    private final class Shared: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [(BulkDirectoryReader.Context) -> Void] = []
        var head = 0
        var isShutDown = false
        var startedThreadCount = 0
        var idleThreadCount = 0
        let maximumThreadCount: Int

        init(maximumThreadCount: Int) {
            self.maximumThreadCount = maximumThreadCount
        }

        func submit(_ job: @escaping (BulkDirectoryReader.Context) -> Void) {
            condition.lock()
            jobs.append(job)
            // Threads start on demand: a traversal that lists one directory
            // never pays for the whole pool.
            let needsThread = idleThreadCount == 0 && startedThreadCount < maximumThreadCount
            if needsThread {
                startedThreadCount += 1
            }
            condition.signal()
            condition.unlock()
            if needsThread {
                let thread = Thread { [self] in work() }
                thread.qualityOfService = .userInitiated
                thread.name = "com.neodisk.directory-io"
                thread.start()
            }
        }

        private func work() {
            let context = BulkDirectoryReader.Context()
            condition.lock()
            while true {
                if head < jobs.count {
                    let job = jobs[head]
                    head += 1
                    if head == jobs.count {
                        jobs.removeAll(keepingCapacity: true)
                        head = 0
                    }
                    condition.unlock()
                    job(context)
                    condition.lock()
                } else if isShutDown {
                    condition.unlock()
                    return
                } else {
                    idleThreadCount += 1
                    condition.wait()
                    idleThreadCount -= 1
                }
            }
        }

        func shutDown() {
            condition.lock()
            isShutDown = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private let shared: Shared

    var workerCount: Int { shared.maximumThreadCount }

    init(workerCount: Int) {
        shared = Shared(maximumThreadCount: max(1, workerCount))
    }

    deinit {
        shared.shutDown()
    }

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable (
            BulkDirectoryReader.Context,
            @escaping CancellationCheck
        ) throws -> Result
    ) async throws -> Result {
        let cancellationState = CancellationState()
        let shared = self.shared

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queued = ScanProfile.started(.ioQueueWait)
                shared.submit { context in
                    ScanProfile.finish(queued)
                    do {
                        try cancellationState.check()
                        let result = try operation(context, cancellationState.check)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }
}
