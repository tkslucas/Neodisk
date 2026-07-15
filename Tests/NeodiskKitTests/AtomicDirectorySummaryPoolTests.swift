import Testing
import Foundation
@testable import NeodiskKit

/// Focused coverage for the scan-wide `AtomicDirectorySummaryPool`: two jobs
/// sharing the worker set, hard-link claim parity through the pooled path, and
/// mid-job cancellation resuming the caller with `CancellationError`.
@Suite struct AtomicDirectorySummaryPoolTests {
    /// Throws `CancellationError` once it has been called more than `throwAfter`
    /// times, so a walk can be cancelled deterministically mid-flight.
    private final class ThrowingCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let throwAfter: Int

        init(throwAfter: Int) {
            self.throwAfter = throwAfter
        }

        func check() throws {
            lock.lock()
            count += 1
            let current = count
            lock.unlock()
            if current > throwAfter {
                throw CancellationError()
            }
        }
    }

    private func makeRequest(
        url: URL,
        cancellationCheck: @escaping CancellationCheck = { }
    ) -> AtomicSummaryPoolRequest {
        AtomicSummaryPoolRequest(
            url: url,
            includeHiddenFiles: true,
            treatPackagesAsDirectories: true,
            ownerNodeID: url.path,
            exclusionMatcher: ScanExclusionMatcher(
                patterns: [],
                rootURL: url,
                includeCloudStorage: true
            ),
            metadataLoader: ScanMetadataLoader(),
            bulkEnumerationEnabled: true,
            cancellationCheck: cancellationCheck
        )
    }

    private func makePool() -> (AtomicDirectorySummaryPool, AsyncThrowingStream<ScanProgressEvent, Error>.Continuation) {
        let (_, continuation) = AsyncThrowingStream<ScanProgressEvent, Error>.makeStream()
        let pool = AtomicDirectorySummaryPool(workerLimit: 4, continuation: continuation)
        return (pool, continuation)
    }

    /// Writes `fileCount` fixed-size files spread across `subdirectoryCount`
    /// nested subdirectories and returns the expected logical byte total.
    @discardableResult
    private func populateTree(
        at root: URL,
        subdirectoryCount: Int,
        filesPerSubdirectory: Int,
        bytesPerFile: Int
    ) throws -> Int64 {
        let payload = Data(repeating: 0x2A, count: bytesPerFile)
        for subdirectoryIndex in 0..<subdirectoryCount {
            let subdirectory = root.appending(path: "sub-\(subdirectoryIndex)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerSubdirectory {
                try payload.write(to: subdirectory.appending(path: "file-\(fileIndex)"))
            }
        }
        return Int64(subdirectoryCount * filesPerSubdirectory * bytesPerFile)
    }

    @Test func twoConcurrentJobsBothSummarizeFully() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobA = root.appending(path: "jobA", directoryHint: .isDirectory)
        let jobB = root.appending(path: "jobB", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jobA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobB, withIntermediateDirectories: true)
        let expectedA = try populateTree(at: jobA, subdirectoryCount: 6, filesPerSubdirectory: 40, bytesPerFile: 512)
        let expectedB = try populateTree(at: jobB, subdirectoryCount: 3, filesPerSubdirectory: 10, bytesPerFile: 256)

        let (pool, continuation) = makePool()
        pool.start()

        async let summaryA = pool.summarize(makeRequest(url: jobA))
        async let summaryB = pool.summarize(makeRequest(url: jobB))
        let (resolvedA, resolvedB) = try await (summaryA, summaryB)
        await pool.finish()
        continuation.finish()

        let unwrappedA = try #require(resolvedA)
        let unwrappedB = try #require(resolvedB)
        #expect(unwrappedA.descendantFileCount == 6 * 40)
        #expect(unwrappedB.descendantFileCount == 3 * 10)
        #expect(unwrappedA.logicalSize == expectedA)
        #expect(unwrappedB.logicalSize == expectedB)
        #expect(unwrappedA.isAccessible)
        #expect(unwrappedB.isAccessible)
    }

    @Test func pooledSummaryEmitsHardLinkClaims() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0x5A, count: 4_096)
        let originalURL = root.appending(path: "original.bin")
        let linkedURL = root.appending(path: "linked.bin")
        try payload.write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let (pool, continuation) = makePool()
        pool.start()
        let summary = try #require(try await pool.summarize(makeRequest(url: root)))
        await pool.finish()
        continuation.finish()

        // Both hard links are counted as files, and each contributes a claim for
        // the shared (device, inode) so downstream dedup charges the storage once.
        #expect(summary.descendantFileCount == 2)
        #expect(summary.hardLinkClaims.count == 2)
        let identities = Set(summary.hardLinkClaims.map(\.identity))
        #expect(identities.count == 1)
    }

    @Test func cancellingMidJobResumesCallerWithCancellationError() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try populateTree(at: root, subdirectoryCount: 8, filesPerSubdirectory: 200, bytesPerFile: 64)

        let counter = ThrowingCounter(throwAfter: 3)
        let (pool, continuation) = makePool()
        pool.start()

        await #expect(throws: CancellationError.self) {
            _ = try await pool.summarize(makeRequest(url: root, cancellationCheck: counter.check))
        }
        // The pool must still tear down cleanly after a cancelled job.
        await pool.finish()
        continuation.finish()
    }

    @Test func preCancelledRequestRejectsBeforeWork() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try populateTree(at: root, subdirectoryCount: 1, filesPerSubdirectory: 1, bytesPerFile: 16)

        let (pool, continuation) = makePool()
        pool.start()

        await #expect(throws: CancellationError.self) {
            _ = try await pool.summarize(makeRequest(url: root, cancellationCheck: { throw CancellationError() }))
        }
        await pool.finish()
        continuation.finish()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-pool-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
