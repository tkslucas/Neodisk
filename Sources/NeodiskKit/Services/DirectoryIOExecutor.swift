//
//  DirectoryIOExecutor.swift
//  Neodisk
//
//  Blocking directory syscalls run on bounded, dedicated serial GCD workers
//  instead of occupying Swift's cooperative executor. Each worker owns one
//  reusable getattrlistbulk context for its lifetime.
//

import Dispatch
import Foundation

nonisolated final class DirectoryIOExecutor: @unchecked Sendable {
    private final class Worker: @unchecked Sendable {
        let queue: DispatchQueue
        let bulkContext = BulkDirectoryReader.Context()

        init(index: Int) {
            queue = DispatchQueue(
                label: "com.neodisk.directory-io.\(index)",
                qos: .userInitiated
            )
        }
    }

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

    private let selectionLock = NSLock()
    private let workers: [Worker]
    private var nextWorkerIndex = 0

    var workerCount: Int { workers.count }

    init(workerCount: Int) {
        workers = (0..<max(1, workerCount)).map(Worker.init(index:))
    }

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable (
            BulkDirectoryReader.Context,
            @escaping CancellationCheck
        ) throws -> Result
    ) async throws -> Result {
        let cancellationState = CancellationState()
        let worker = selectWorker()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.queue.async {
                    do {
                        try cancellationState.check()
                        let result = try operation(
                            worker.bulkContext,
                            cancellationState.check
                        )
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

    private func selectWorker() -> Worker {
        selectionLock.lock()
        let worker = workers[nextWorkerIndex]
        nextWorkerIndex = (nextWorkerIndex + 1) % workers.count
        selectionLock.unlock()
        return worker
    }
}
