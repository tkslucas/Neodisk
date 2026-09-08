import Foundation
import Testing
@testable import NeodiskKit

@Suite struct TaskCancellationTests {
    @Test func cancellationBeforeAwaitReachesDetachedWorker() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let worker = Task.detached {
            for await _ in stream {}
            return Task.isCancelled
        }
        let parent = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await worker.cancellableValue
        }
        #expect(await parent.value)
    }

    @Test func throwingWorkerReceivesParentCancellation() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let worker = Task.detached {
            for await _ in stream {}
            try Task.checkCancellation()
        }
        let parent = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await worker.cancellableValue
        }
        do {
            try await parent.value
            Issue.record("Worker did not receive cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
