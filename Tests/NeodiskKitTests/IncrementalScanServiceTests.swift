import Foundation
import Testing
@testable import NeodiskKit

/// End-to-end incremental rescans over a real temp-dir tree, with the
/// FSEvents journal replaced by a scripted stub — deterministic without
/// depending on fseventsd timing. The real-journal path is covered by
/// FileSystemEventHistoryProviderTests.
@Suite("IncrementalScanService", .serialized)
struct IncrementalScanServiceTests {
    // MARK: - Stub provider

    final class StubEventHistoryProvider: FileSystemEventHistoryProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var checkpoints: [FSEventsCheckpoint]
        private var historyResult: Result<FileSystemEventHistory, Error>
        private(set) var historyRequests: [(since: UInt64, through: UInt64)] = []

        init(
            checkpoints: [FSEventsCheckpoint],
            history: Result<FileSystemEventHistory, Error> = .success(FileSystemEventHistory(events: []))
        ) {
            self.checkpoints = checkpoints
            self.historyResult = history
        }

        func setHistory(_ result: Result<FileSystemEventHistory, Error>) {
            lock.lock()
            defer { lock.unlock() }
            historyResult = result
        }

        func currentCheckpoint(for target: ScanTarget) throws -> FSEventsCheckpoint {
            lock.lock()
            defer { lock.unlock() }
            guard let next = checkpoints.first else {
                throw FileSystemEventHistoryError.eventIDUnavailable
            }
            if checkpoints.count > 1 {
                checkpoints.removeFirst()
            }
            return next
        }

        func history(
            since: FSEventsCheckpoint,
            through: FSEventsCheckpoint,
            target: ScanTarget
        ) async throws -> FileSystemEventHistory {
            let result: Result<FileSystemEventHistory, Error> = {
                lock.lock()
                defer { lock.unlock() }
                historyRequests.append((since: since.eventID, through: through.eventID))
                return historyResult
            }()
            return try result.get()
        }

        var recordedRequests: [(since: UInt64, through: UInt64)] {
            lock.lock()
            defer { lock.unlock() }
            return historyRequests
        }
    }

    // MARK: - Fixture

    private func checkpoint(_ eventID: UInt64) -> FSEventsCheckpoint {
        FSEventsCheckpoint(volumeUUID: "STUB-UUID", eventID: eventID, capturedAt: Date(), osBuild: "TEST")
    }

    private func makeTemporaryTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "incremental-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let alpha = root.appending(path: "alpha", directoryHint: .isDirectory)
        let beta = root.appending(path: "beta", directoryHint: .isDirectory)
        let nested = alpha.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 4_096).write(to: alpha.appending(path: "a.bin"))
        try Data(repeating: 0x62, count: 8_192).write(to: nested.appending(path: "deep.bin"))
        try Data(repeating: 0x63, count: 2_048).write(to: beta.appending(path: "b.bin"))
        return root
    }

    private func finishedSnapshot(
        from stream: AsyncThrowingStream<ScanProgressEvent, Error>
    ) async throws -> ScanSnapshot? {
        var finished: ScanSnapshot?
        for try await event in stream {
            if case .finished(let snapshot) = event {
                finished = snapshot
            }
        }
        return finished
    }

    /// Node-for-node equivalence on the fields a user can observe. Directory
    /// mtimes are excluded on purpose: both trees are scanned after the same
    /// mutations, but HFS-level timestamp granularity can still differ.
    private func expectEquivalentTrees(
        _ lhs: FileTreeStore,
        _ rhs: FileTreeStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let lhsNodes = lhs.allNodes.sorted { $0.id < $1.id }
        let rhsNodes = rhs.allNodes.sorted { $0.id < $1.id }
        #expect(lhsNodes.count == rhsNodes.count, sourceLocation: sourceLocation)
        for (a, b) in zip(lhsNodes, rhsNodes) {
            #expect(a.id == b.id, sourceLocation: sourceLocation)
            #expect(a.isDirectory == b.isDirectory, "\(a.id)", sourceLocation: sourceLocation)
            #expect(a.allocatedSize == b.allocatedSize, "\(a.id)", sourceLocation: sourceLocation)
            #expect(a.logicalSize == b.logicalSize, "\(a.id)", sourceLocation: sourceLocation)
            #expect(a.descendantFileCount == b.descendantFileCount, "\(a.id)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Tests

    @Test func incrementalSpliceMatchesFreshFullScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()

        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        #expect(baseline.incrementalCheckpoint?.eventID == 10)
        #expect(baseline.scanOptions != nil)

        // Mutate alpha: grow a file, add one; beta untouched.
        let alpha = root.appending(path: "alpha", directoryHint: .isDirectory)
        try Data(repeating: 0x64, count: 16_384).write(to: alpha.appending(path: "grown.bin"))
        try Data(repeating: 0x65, count: 12_288).write(
            to: alpha.appending(path: "nested/deep.bin", directoryHint: .notDirectory)
        )

        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/alpha/grown.bin", eventID: 15, flags: [.itemCreated]),
            FileSystemChangeEvent(path: target.id + "/alpha/nested/deep.bin", eventID: 16, flags: []),
        ])))

        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))

        expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
        #expect(rescanned.incrementalCheckpoint?.eventID == 20)
        #expect(rescanned.isComplete)
        #expect(rescanned.id != baseline.id)
        let requests = provider.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.since == 10)
        #expect(requests.first?.through == 20)
    }

    @Test func noChangesAdvancesCheckpointOnSameTree() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))

        #expect(rescanned.incrementalCheckpoint?.eventID == 20)
        #expect(rescanned.id != baseline.id)
        expectEquivalentTrees(rescanned.treeStore, baseline.treeStore)
    }

    @Test func providerValidationFailureFallsBackToFullScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(
            checkpoints: [checkpoint(10), checkpoint(20)],
            history: .failure(FileSystemEventHistoryError.volumeChanged)
        )
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        try Data(repeating: 0x66, count: 6_144).write(
            to: root.appending(path: "beta/late.bin", directoryHint: .notDirectory)
        )
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))

        // The fallback full scan sees the late file the (refused) journal
        // replay was never consulted about.
        expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
        #expect(rescanned.incrementalCheckpoint != nil)
    }

    @Test func changedShapeOptionsFallBackWithoutConsultingHistory() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: ScanOptions())
        ))

        var hidden = ScanOptions()
        hidden.includeHiddenFiles = true
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: hidden, baselineProvider: { baseline })
        ))

        #expect(rescanned.isComplete)
        #expect(provider.recordedRequests.isEmpty)
    }

    @Test func missingCheckpointFallsBackWithoutConsultingHistory() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        // A baseline decoded from an old cache file carries no checkpoint.
        let bare = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { bare })
        ))

        #expect(rescanned.isComplete)
        #expect(provider.recordedRequests.isEmpty)
        // The fallback still captured a fresh checkpoint for next time.
        #expect(rescanned.incrementalCheckpoint?.eventID == 20)
    }

    @Test func killSwitchDisablesIncrementalPath() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider, isEnabled: false)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))

        #expect(rescanned.isComplete)
        #expect(provider.recordedRequests.isEmpty)
    }

    @Test func vanishedSubtreeFallsBackToFullScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))

        // beta is deleted on disk but the journal only reports a change
        // INSIDE it, so the planner targets a directory whose sub-scan hits
        // a missing root — the recover-not-throw path (Radix 08d06c2).
        let beta = root.appending(path: "beta", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: beta)
        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/beta/b.bin", eventID: 15, flags: []),
        ])))

        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))
        expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
    }

    @Test func staleWarningsUnderRescannedSubtreeArePruned() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let scanned = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        let staleWarning = ScanWarning(
            path: target.id + "/alpha/nested",
            message: "was unreadable",
            category: .permissionDenied
        )
        let keptWarning = ScanWarning(
            path: target.id + "/beta/b.bin",
            message: "still relevant",
            category: .fileSystem
        )
        let baseline = ScanSnapshot(
            target: scanned.target,
            treeStore: scanned.treeStore,
            startedAt: scanned.startedAt,
            finishedAt: scanned.finishedAt,
            scanWarnings: [staleWarning, keptWarning],
            aggregateStats: scanned.aggregateStats,
            isComplete: true,
            scanOptions: scanned.scanOptions,
            incrementalCheckpoint: scanned.incrementalCheckpoint
        )

        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/alpha/a.bin", eventID: 15, flags: []),
        ])))
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))

        #expect(!rescanned.scanWarnings.contains(staleWarning))
        #expect(rescanned.scanWarnings.contains(keptWarning))
    }

    /// Whole chain against the real fseventsd journal: capture → mutate →
    /// replay → plan → splice. Self-skips when the volume has no usable
    /// journal (the checkpoint capture fails). The journal write is
    /// asynchronous, so the rescan polls until the change surfaces.
    @Test(.timeLimit(.minutes(1))) func realJournalRescanConvergesToFreshScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let service = IncrementalScanService(
            engine: ScanEngine(),
            historyProvider: DarwinFileSystemEventHistoryProvider()
        )

        guard let baseline = try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ), baseline.incrementalCheckpoint != nil else {
            FileHandle.standardError.write(Data("realJournal test: SKIPPED (no checkpoint)\n".utf8))
            return // No journal on this volume; the stubbed suites cover the logic.
        }

        let grown = root.appending(path: "alpha/grown.bin", directoryHint: .notDirectory)
        try Data(repeating: 0x64, count: 16_384).write(to: grown)

        for _ in 0..<40 {
            let rescanned = try #require(try await finishedSnapshot(
                from: service.rescan(target: target, options: options, baselineProvider: { baseline })
            ))
            if rescanned.treeStore.node(id: grown.path) != nil {
                let fresh = try #require(try await finishedSnapshot(
                    from: ScanEngine().scan(target: target, options: options)
                ))
                expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("the journal never surfaced the mutation within the deadline")
    }

    @Test func cancellationEndsStreamWithoutFinished() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))

        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/alpha/a.bin", eventID: 15, flags: []),
        ])))
        let consumer = Task {
            var sawFinished = false
            do {
                for try await event in service.rescan(
                    target: target,
                    options: options,
                    baselineProvider: {
                        // Cancelled while the baseline is still loading —
                        // the earliest and most common cancellation window.
                        try? await Task.sleep(for: .seconds(30))
                        return baseline
                    }
                ) {
                    if case .finished = event { sawFinished = true }
                }
            } catch {
                return false
            }
            return sawFinished
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        let sawFinished = await consumer.value
        #expect(!sawFinished)
    }
}
