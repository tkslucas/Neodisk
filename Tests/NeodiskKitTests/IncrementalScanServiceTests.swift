import Foundation
import Testing
@testable import NeodiskKit

/// End-to-end incremental rescans over a temp-dir tree with a scripted FSEvents stub, so tests don't
/// depend on fseventsd timing.
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

    /// One file's two hard links live in different top-level subtrees, so dedup must reconcile across a
    /// splice. A splice that forgets to rebalance leaves the changed subtree's link double-counted.
    private func makeHardLinkTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "incremental-hardlink-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let owner = root.appending(path: "A-Owner", directoryHint: .isDirectory)
        let changed = root.appending(path: "Z-Changed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        // Filler so neither subtree is just the shared file.
        try Data(repeating: 0x61, count: 4_096).write(to: owner.appending(path: "owner-only.bin"))
        try Data(repeating: 0x62, count: 2_048).write(to: changed.appending(path: "changed-only.bin"))
        // The shared payload, hard-linked into both subtrees.
        let shared = owner.appending(path: "shared.bin")
        try Data(repeating: 0x63, count: 16_384).write(to: shared)
        try FileManager.default.linkItem(at: shared, to: changed.appending(path: "shared.bin"))
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

    /// Directory mtimes are excluded: timestamp granularity can differ even after the same mutations.
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

    /// Hard-link parity (identity, link count, raw and deduped sizes, child order); catches a mis-rebalanced
    /// cross-subtree link that `expectEquivalentTrees` can miss.
    private func expectHardLinkParity(
        _ lhs: FileTreeStore,
        _ rhs: FileTreeStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            lhs.indexedNodeIDs().sorted() == rhs.indexedNodeIDs().sorted(),
            sourceLocation: sourceLocation
        )
        for id in rhs.indexedNodeIDs() {
            guard let a = lhs.node(id: id), let b = rhs.node(id: id) else {
                Issue.record("missing node \(id)", sourceLocation: sourceLocation)
                continue
            }
            #expect(a.isDirectory == b.isDirectory, "\(id)", sourceLocation: sourceLocation)
            #expect(a.isSymbolicLink == b.isSymbolicLink, "\(id)", sourceLocation: sourceLocation)
            #expect(a.allocatedSize == b.allocatedSize, "\(id)", sourceLocation: sourceLocation)
            #expect(
                a.unduplicatedAllocatedSize == b.unduplicatedAllocatedSize,
                "\(id)",
                sourceLocation: sourceLocation
            )
            #expect(a.logicalSize == b.logicalSize, "\(id)", sourceLocation: sourceLocation)
            #expect(a.descendantFileCount == b.descendantFileCount, "\(id)", sourceLocation: sourceLocation)
            // Identity drives hard-link dedup and rename detection, so it must match a fresh scan, including a
            // rescanned subtree's root.
            #expect(a.fileIdentity == b.fileIdentity, "\(id)", sourceLocation: sourceLocation)
            #expect(a.linkCount == b.linkCount, "\(id)", sourceLocation: sourceLocation)
            #expect(a.isPackage == b.isPackage, "\(id)", sourceLocation: sourceLocation)
            #expect(a.isSynthetic == b.isSynthetic, "\(id)", sourceLocation: sourceLocation)
            #expect(
                lhs.children(of: id).map(\.id) == rhs.children(of: id).map(\.id),
                "\(id)",
                sourceLocation: sourceLocation
            )
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

    @Test func independentSubtreesRescanTogetherAndSpliceDeterministically() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        try Data(repeating: 0x71, count: 7_000).write(
            to: root.appending(path: "alpha/parallel-a.bin")
        )
        try Data(repeating: 0x72, count: 9_000).write(
            to: root.appending(path: "beta/parallel-b.bin")
        )
        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/alpha/parallel-a.bin", eventID: 15, flags: [.itemCreated]),
            FileSystemChangeEvent(path: target.id + "/beta/parallel-b.bin", eventID: 16, flags: [.itemCreated]),
        ])))

        var progressFractions: [Double] = []
        var rescanned: ScanSnapshot?
        for try await event in service.rescan(
            target: target,
            options: options,
            baselineProvider: { baseline }
        ) {
            if case .progress(let metrics) = event {
                progressFractions.append(metrics.progressFraction)
            } else if case .finished(let snapshot) = event {
                rescanned = snapshot
            }
        }
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))
        let result = try #require(rescanned)

        expectEquivalentTrees(result.treeStore, fresh.treeStore)
        #expect(result.incrementalCheckpoint?.eventID == 20)
        #expect(progressFractions == progressFractions.sorted())
    }

    /// The rescanned subtree sees the shared file as unlinked (its twin is out of scope), so the splice must
    /// re-run global hard-link dedup.
    @Test func incrementalSpliceMatchesFreshFullScanForHardLinksAcrossSubtrees() async throws {
        let root = try makeHardLinkTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()

        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        #expect(baseline.incrementalCheckpoint?.eventID == 10)

        // Proves the fixture exercises dedup, or the parity check below is vacuous.
        let ownerLink = try #require(baseline.treeStore.node(id: target.id + "/A-Owner/shared.bin"))
        let changedLink = try #require(baseline.treeStore.node(id: target.id + "/Z-Changed/shared.bin"))
        #expect(ownerLink.linkCount == 2)
        #expect(ownerLink.fileIdentity != nil)
        #expect(ownerLink.fileIdentity == changedLink.fileIdentity)
        #expect(ownerLink.allocatedSize == ownerLink.unduplicatedAllocatedSize)
        #expect(changedLink.allocatedSize < changedLink.unduplicatedAllocatedSize)

        // Grow the changed subtree so the journal names it. The planner then
        // re-scans exactly that subtree — the one holding the deduped link.
        let changedDir = root.appending(path: "Z-Changed", directoryHint: .isDirectory)
        try Data(repeating: 0x64, count: 8_192).write(to: changedDir.appending(path: "added.bin"))
        let events = [
            FileSystemChangeEvent(path: target.id + "/Z-Changed/added.bin", eventID: 15, flags: [.itemCreated]),
        ]
        provider.setHistory(.success(FileSystemEventHistory(events: events)))

        // Requires the planner to resolve these events to a subtree splice, not a silent full-scan fallback.
        let behavior = ScanEngine.ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )
        let matcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path,
            includeCloudStorage: options.includeCloudStorage,
            cloudStorageRootPath: options.cloudStorageRootPath,
            iCloudDriveRootPath: options.iCloudDriveRootPath
        )
        let plan = IncrementalRescanPlanner.plan(
            events: events,
            target: target,
            baseline: baseline.treeStore,
            options: options,
            behavior: behavior,
            exclusionMatcher: matcher
        )
        #expect(plan == .relistDirectories(dirIDs: [target.id + "/Z-Changed"], deepRescanRootIDs: []))

        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))

        // The spliced tree must match a from-scratch scan node-for-node,
        // including the rebalanced cross-subtree hard link, and in totals.
        expectHardLinkParity(rescanned.treeStore, fresh.treeStore)
        #expect(rescanned.aggregateStats.totalAllocatedSize == fresh.aggregateStats.totalAllocatedSize)
        #expect(rescanned.aggregateStats.totalLogicalSize == fresh.aggregateStats.totalLogicalSize)
        #expect(rescanned.aggregateStats.fileCount == fresh.aggregateStats.fileCount)
        #expect(rescanned.aggregateStats.directoryCount == fresh.aggregateStats.directoryCount)

        // The isolated sub-scan saw this link at full size; a rebalance-less splice would leave it there.
        let splicedChangedLink = try #require(rescanned.treeStore.node(id: target.id + "/Z-Changed/shared.bin"))
        #expect(splicedChangedLink.allocatedSize < splicedChangedLink.unduplicatedAllocatedSize)

        // The subtree root comes from the single-URL metadata load, not the bulk reader; check it got an identity.
        #expect(rescanned.treeStore.node(id: target.id + "/Z-Changed")?.fileIdentity != nil)

        // And the incremental machinery actually ran: history was consulted
        // exactly once over the baseline→cutoff window, advancing the checkpoint.
        #expect(rescanned.incrementalCheckpoint?.eventID == 20)
        #expect(rescanned.isComplete)
        #expect(rescanned.id != baseline.id)
        let requests = provider.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.since == 10)
        #expect(requests.first?.through == 20)
    }

    /// The journal names only the new link and the old one still reads link count 1, so a relist would
    /// double-count; the hard-link flag must force a full scan.
    @Test func newHardLinkFallsBackToFullScanAndMatchesFreshScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        let original = try #require(baseline.treeStore.node(id: target.id + "/alpha/a.bin"))
        #expect(original.linkCount == 1)

        try FileManager.default.linkItem(
            at: root.appending(path: "alpha/a.bin"),
            to: root.appending(path: "beta/a-link.bin")
        )
        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(
                path: target.id + "/beta/a-link.bin",
                eventID: 15,
                flags: [.itemCreated, .itemIsHardLink]
            ),
        ])))

        var progress: [ScanMetrics] = []
        var finished: ScanSnapshot?
        for try await event in service.rescan(target: target, options: options, baselineProvider: { baseline }) {
            switch event {
            case .progress(let metrics): progress.append(metrics)
            case .finished(let snapshot): finished = snapshot
            default: break
            }
        }
        let rescanned = try #require(finished)
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))

        #expect(progress.contains { $0.isFullScanFallback })
        expectHardLinkParity(rescanned.treeStore, fresh.treeStore)
        #expect(rescanned.aggregateStats.totalAllocatedSize == fresh.aggregateStats.totalAllocatedSize)
        // The shared bytes are counted once: adding a second link to an
        // existing file leaves the total where the baseline had it.
        #expect(rescanned.aggregateStats.totalAllocatedSize == baseline.aggregateStats.totalAllocatedSize)
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

    @Test func rescanProgressStartsFromRetainedBaselineTotals() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        let beta = root.appending(path: "beta", directoryHint: .isDirectory)
        try Data(repeating: 0x66, count: 6_144).write(to: beta.appending(path: "new.bin"))
        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/beta/new.bin", eventID: 15, flags: [.itemCreated]),
        ])))

        var progress: [ScanMetrics] = []
        var finished: ScanSnapshot?
        for try await event in service.rescan(target: target, options: options, baselineProvider: { baseline }) {
            switch event {
            case .progress(let metrics): progress.append(metrics)
            case .finished(let snapshot): finished = snapshot
            default: break
            }
        }

        // The stream opens with the silent preparation phase flagged, so the
        // strip can show "Checking for changes…" instead of a dead bar.
        let first = try #require(progress.first)
        #expect(first.isCheckingChanges)
        #expect(progress.drop(while: \.isCheckingChanges).allSatisfy { !$0.isCheckingChanges })

        // Counters open at the baseline totals the relist retains, not zero; this churn only inserts, so the
        // seed is the full baseline.
        let seed = try #require(progress.first { !$0.isCheckingChanges })
        #expect(seed.filesVisited == baseline.aggregateStats.fileCount)
        #expect(seed.bytesDiscovered == baseline.aggregateStats.totalAllocatedSize)

        // The bar opens at the retained share of the baseline's bytes and
        // never moves backward from there.
        let retained = Double(seed.bytesDiscovered)
            / Double(baseline.aggregateStats.totalAllocatedSize)
        #expect(abs(seed.progressFraction - min(retained, ScanMetrics.traversalSpan)) < 0.0001)
        #expect(seed.progressFraction > 0)
        let fractions = progress.map(\.progressFraction)
        #expect(fractions == fractions.sorted())
        #expect(progress.contains { $0.isMergingChanges && $0.isFinalizing })
        // The merge phase must report moving progress, not a static hold at the rescan ceiling.
        #expect(progress.contains {
            $0.isMergingChanges
                && $0.progressFraction > ScanMetrics.traversalSpan
                && $0.progressFraction < 1
        })

        // And closes at exactly the spliced snapshot's totals.
        let last = try #require(progress.last)
        let snapshot = try #require(finished)
        #expect(last.filesVisited == snapshot.aggregateStats.fileCount)
        #expect(last.bytesDiscovered == snapshot.aggregateStats.totalAllocatedSize)
        #expect(last.progressFraction == 1)
        #expect(!last.isMergingChanges)
    }

    /// Runs the same planner the service runs, so a relist test proves it took
    /// the relist path rather than a silent full-scan fallback.
    private func plannedResult(
        events: [FileSystemChangeEvent],
        target: ScanTarget,
        baseline: FileTreeStore,
        options: ScanOptions
    ) -> IncrementalRescanPlan {
        IncrementalRescanPlanner.plan(
            events: events,
            target: target,
            baseline: baseline,
            options: options,
            behavior: ScanEngine.ScanBehavior(
                excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
            ),
            exclusionMatcher: ScanExclusionMatcher(
                patterns: options.exclusionPatterns,
                rootPath: options.exclusionRootPath ?? target.url.path,
                includeCloudStorage: options.includeCloudStorage,
                cloudStorageRootPath: options.cloudStorageRootPath,
                iCloudDriveRootPath: options.iCloudDriveRootPath
            )
        )
    }

    /// New root-level entries relist the root (not a full scan), and the splice must match a fresh scan.
    @Test func rootMembershipAdditionRelistsAndMatchesFullScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))

        try Data(repeating: 0x7A, count: 5_000).write(to: root.appending(path: "newtop.bin"))
        let gamma = root.appending(path: "gamma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gamma, withIntermediateDirectories: true)
        try Data(repeating: 0x7B, count: 9_000).write(to: gamma.appending(path: "g.bin"))
        let events = [
            FileSystemChangeEvent(path: target.id + "/newtop.bin", eventID: 15, flags: [.itemCreated]),
            FileSystemChangeEvent(path: target.id + "/gamma", eventID: 16, flags: [.itemCreated, .itemIsDirectory]),
        ]
        provider.setHistory(.success(FileSystemEventHistory(events: events)))

        // The event window resolves to a root relist, never a full scan.
        guard case .relistDirectories(let dirIDs, _) = plannedResult(
            events: events, target: target, baseline: baseline.treeStore, options: options
        ), dirIDs.contains(target.id) else {
            Issue.record("expected a root relist plan")
            return
        }

        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))

        expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
        #expect(rescanned.aggregateStats.totalAllocatedSize == fresh.aggregateStats.totalAllocatedSize)
        #expect(rescanned.aggregateStats.fileCount == fresh.aggregateStats.fileCount)
        #expect(rescanned.treeStore.node(id: target.id + "/newtop.bin") != nil)
        #expect(rescanned.treeStore.node(id: target.id + "/gamma/g.bin") != nil)
        #expect(rescanned.incrementalCheckpoint?.eventID == 20)
        #expect(provider.recordedRequests.count == 1)
    }

    /// A top-level directory is deleted; the relist removes its subtree and the
    /// result matches a fresh scan (the removed subtree is gone from both).
    @Test func rootMembershipRemovalRelistsAndMatchesFullScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        #expect(baseline.treeStore.node(id: target.id + "/beta") != nil)

        try FileManager.default.removeItem(at: root.appending(path: "beta", directoryHint: .isDirectory))
        let events = [
            FileSystemChangeEvent(path: target.id + "/beta", eventID: 15, flags: [.itemRemoved, .itemIsDirectory]),
        ]
        provider.setHistory(.success(FileSystemEventHistory(events: events)))

        guard case .relistDirectories(let dirIDs, _) = plannedResult(
            events: events, target: target, baseline: baseline.treeStore, options: options
        ), dirIDs.contains(target.id) else {
            Issue.record("expected a root relist plan")
            return
        }

        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))
        expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
        #expect(rescanned.treeStore.node(id: target.id + "/beta") == nil)
        #expect(rescanned.aggregateStats.totalAllocatedSize == fresh.aggregateStats.totalAllocatedSize)
    }

    /// A direct-child file's event maps to the root, so the relist replaces just that file's record.
    @Test func directChildFileChangeRelistsAndMatchesFullScan() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Seed a top-level file so the baseline has a direct-child leaf.
        try Data(repeating: 0x31, count: 2_048).write(to: root.appending(path: "topfile.bin"))
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        let baselineTop = try #require(baseline.treeStore.node(id: target.id + "/topfile.bin"))

        try Data(repeating: 0x32, count: 20_480).write(to: root.appending(path: "topfile.bin"))
        let events = [
            FileSystemChangeEvent(path: target.id + "/topfile.bin", eventID: 15, flags: []),
        ]
        provider.setHistory(.success(FileSystemEventHistory(events: events)))

        guard case .relistDirectories(let dirIDs, _) = plannedResult(
            events: events, target: target, baseline: baseline.treeStore, options: options
        ), dirIDs.contains(target.id) else {
            Issue.record("expected a root relist plan")
            return
        }

        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))
        let fresh = try #require(try await finishedSnapshot(
            from: ScanEngine().scan(target: target, options: options)
        ))
        expectEquivalentTrees(rescanned.treeStore, fresh.treeStore)
        let rescannedTop = try #require(rescanned.treeStore.node(id: target.id + "/topfile.bin"))
        #expect(rescannedTop.allocatedSize > baselineTop.allocatedSize)
        #expect(rescannedTop.allocatedSize == fresh.treeStore.node(id: target.id + "/topfile.bin")?.allocatedSize)
    }

    /// A mid-flight fallback (mapped subtree vanished) must not step the bar back and must flag the fallback.
    @Test func fallbackFullScanKeepsBarMonotonicAndIsFlagged() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))
        // A coalesced event on beta forces a deep re-walk, which fails on the missing directory and falls back
        // to a full scan after progress has advanced.
        try FileManager.default.removeItem(at: root.appending(path: "beta", directoryHint: .isDirectory))
        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(
                path: target.id + "/beta",
                eventID: 15,
                flags: [.itemIsDirectory, .mustScanSubdirectories]
            ),
        ])))

        var progress: [ScanMetrics] = []
        var finished: ScanSnapshot?
        for try await event in service.rescan(target: target, options: options, baselineProvider: { baseline }) {
            switch event {
            case .progress(let metrics): progress.append(metrics)
            case .finished(let snapshot): finished = snapshot
            default: break
            }
        }
        _ = try #require(finished)

        let fractions = progress.map(\.progressFraction)
        #expect(fractions == fractions.sorted())
        #expect(progress.contains { $0.isFullScanFallback })
        // The retained seed opens the bar above zero, and the fallback resumes
        // forward from there rather than resetting.
        let firstFallback = try #require(progress.first { $0.isFullScanFallback })
        let lastBeforeFallback = progress.prefix(while: { !$0.isFullScanFallback }).last
        if let lastBeforeFallback {
            #expect(firstFallback.progressFraction >= lastBeforeFallback.progressFraction)
        }
        #expect(abs((progress.last?.progressFraction ?? 0) - 1) < 0.0001)
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

    @Test func vanishedRelistTargetIsRemovedNotFullScanned() async throws {
        let root = try makeTemporaryTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = StubEventHistoryProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        let baseline = try #require(try await finishedSnapshot(
            from: service.scan(target: target, options: options)
        ))

        // The journal reports a change inside beta only, so the relist targets beta, finds it gone and removes
        // it in place without a full traversal.
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

        // Relisting the warned directory prunes its stale warning; the untouched one elsewhere survives.
        provider.setHistory(.success(FileSystemEventHistory(events: [
            FileSystemChangeEvent(path: target.id + "/alpha/nested", eventID: 15, flags: [.itemIsDirectory]),
        ])))
        let rescanned = try #require(try await finishedSnapshot(
            from: service.rescan(target: target, options: options, baselineProvider: { baseline })
        ))

        #expect(!rescanned.scanWarnings.contains(staleWarning))
        #expect(rescanned.scanWarnings.contains(keptWarning))
    }

    #if canImport(CoreServices)
    /// Against the real fseventsd journal; self-skips without a usable journal. The journal write is async,
    /// so the rescan polls until the change surfaces.
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
    #endif

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
