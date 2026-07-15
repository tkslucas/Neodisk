import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Characterization tests pinning `startScan`'s branch selection and the
/// snapshot-cache bookkeeping it drives (restore vs refresh vs live scan,
/// notice suppression, date adoption, rotation, sidecars). These lock in the
/// CURRENT behavior ahead of a refactor of the scan lifecycle; they are not
/// aspirational. Scenarios already covered by
/// NeodiskViewModelSnapshotCacheTests are intentionally not duplicated here.
@MainActor
@Suite(.serialized) struct ScanLifecycleTests {
    /// Switching back to a location scanned earlier this session shows its map
    /// instantly from session memory while a refresh runs behind it — no disk
    /// decode, no notice — even when another target's scan is in flight.
    @Test func testRecentInMemorySnapshotReselectRefreshesFromMemory() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/scan-life/recent-a")
        let targetB = makeTestTarget("/scan-life/recent-b")
        environment.sidebarFolderStore.add(targetA)
        environment.sidebarFolderStore.add(targetB)
        // .automatic never skips a rescan, so reselecting A always refreshes.
        let model = environment.makeModel(policy: .automatic)

        // Scan A to completion so its finished snapshot enters session memory.
        model.startScan(targetA)
        environment.scanService.yield(.finished(makeSnapshot(target: targetA)), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("A finished and displayed") {
            model.coordinator.snapshot?.target.id == targetA.id
                && model.coordinator.snapshot?.isComplete == true
        }

        // Move to B (a live scan of a never-seen target).
        model.startScan(targetB)
        let countBeforeReselect = environment.scanService.scanCount

        // Reselect A: the recent-in-memory branch retains A's snapshot and
        // refreshes behind it without touching the disk.
        model.startScan(targetA)

        #expect(environment.scanService.scanCount > countBeforeReselect)
        #expect(model.coordinator.isScanning)
        #expect(model.coordinator.snapshot?.target.id == targetA.id)
        #expect(model.coordinator.snapshot?.isComplete == true)
        #expect(model.session.snapshotNotice == nil)
        model.stopScan()
    }

    /// Rescanning the location already on screen keeps its complete map up and
    /// refreshes behind it — the map never blanks and no notice appears.
    @Test func testRescanOfOnScreenTargetRefreshesBehindMap() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/onscreen")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel(policy: .automatic)

        model.startScan(target)
        environment.scanService.yield(.finished(makeSnapshot(target: target)), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("scan finished and displayed") {
            model.coordinator.snapshot?.isComplete == true
                && model.coordinator.phase == .displaying
        }

        model.startScan(target)

        #expect(model.coordinator.isScanning)
        #expect(model.coordinator.snapshot?.target.id == target.id)
        #expect(model.coordinator.snapshot?.isComplete == true)
        #expect(model.session.snapshotNotice == nil)
        #expect(environment.scanService.scanCount == 2)
        model.stopScan()
    }

    /// Under the smart policy, a location whose last scan was fast auto-rescans:
    /// the cached snapshot shows immediately and a refresh starts behind it,
    /// with no notice (only slow last scans go snapshot-only under smart).
    @Test func testSmartPolicyFastLastScanAutoRescans() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/smart-fast")
        environment.sidebarFolderStore.add(target)
        // ~1s last scan — well under the 15s smart threshold.
        try await environment.cache.save(makeSnapshot(
            target: target,
            startedAt: Date(timeIntervalSinceNow: -1),
            finishedAt: Date()
        ))

        let model = environment.makeModel(policy: .smart)
        try await waitUntilAsync("prune indexes the fast snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }

        model.startScan(target)

        try await waitUntilAsync("cached snapshot displayed during refresh") {
            model.coordinator.isScanning && model.coordinator.snapshot?.isComplete == true
        }
        #expect(model.coordinator.snapshot?.target.id == target.id)
        #expect(model.session.snapshotNotice == nil)
        #expect(environment.scanService.scanCount == 1)
        model.stopScan()
    }

    /// A persisted snapshot that decodes to garbage is not a dead end: the
    /// snapshot-only restore falls back to a live scan and forgets the cache
    /// entry so the location is not stuck showing nothing.
    @Test func testCorruptPersistedSnapshotFallsBackToLiveScan() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/corrupt")
        environment.sidebarFolderStore.add(target)
        try await environment.cache.save(makeSnapshot(target: target))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }

        // Overwrite every cache file with garbage so the decode fails.
        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: environment.cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for url in cacheFiles {
            try Data("not a snapshot".utf8).write(to: url)
        }

        model.startScan(target)

        try await waitUntilAsync("live scan started after corrupt decode") {
            environment.scanService.scanCount == 1
        }
        try await waitUntilAsync("cache entry forgotten") {
            model.session.cachedScanInfo[target.id] == nil
        }
        model.stopScan()
    }

    /// The launch race: startScan fires before the prune index is ready, so
    /// the refresh scan starts optimistically. When the decoded snapshot
    /// reveals the last scan was expensive (snapshot-only policy always
    /// skips), restoreCachedSnapshot cancels the in-flight refresh and offers
    /// a notice instead — the pre-index equivalent of the indexed skip path.
    @Test func testPreIndexRaceCancelsRefreshForSlowSnapshot() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/pre-index-slow")
        environment.sidebarFolderStore.add(target)
        // Four-minute last scan.
        try await environment.cache.save(makeSnapshot(
            target: target,
            startedAt: Date(timeIntervalSinceNow: -300),
            finishedAt: Date(timeIntervalSinceNow: -60)
        ))

        let model = environment.makeModel(policy: .snapshotOnly)
        // Do NOT wait for the prune index: call startScan in the same turn,
        // before the launch prune Task can flip hasIndexedSnapshotCache.
        model.startScan(target)

        try await waitUntilAsync("refresh cancelled, snapshot restored with notice") {
            model.session.snapshotNotice?.targetID == target.id
                && !model.coordinator.isScanning
                && model.coordinator.snapshot?.isComplete == true
        }
        #expect(model.coordinator.snapshot?.target.id == target.id)
    }

    /// When another Neodisk process wrote a newer snapshot after this one's
    /// launch prune, the in-memory index date is stale. Restoring the decoded
    /// snapshot adopts its finish date so the sidebar's "Scanned … ago" matches
    /// what is actually on screen.
    @Test func testStaleIndexDateAdoptsDecodedSnapshotDate() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/stale-date")
        environment.sidebarFolderStore.add(target)
        // The snapshot the launch prune will index finished 100s ago.
        try await environment.cache.save(makeSnapshot(
            target: target,
            startedAt: Date(timeIntervalSinceNow: -101),
            finishedAt: Date(timeIntervalSinceNow: -100)
        ))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the old snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }

        // A newer scan lands on disk directly (a second process), leaving the
        // in-memory index date stale by ~100s.
        let newerFinishedAt = Date()
        try await environment.cache.save(makeSnapshot(
            target: target,
            startedAt: Date(timeIntervalSinceNow: -1),
            finishedAt: newerFinishedAt
        ))
        model.coordinator.forgetAllRecentSnapshots()

        model.startScan(target)

        try await waitUntilAsync("snapshot restored without scanning") {
            model.coordinator.phase == .displaying
        }
        try await waitUntilAsync("index date adopts the decoded snapshot's date") {
            guard let info = model.session.cachedScanInfo[target.id] else { return false }
            return abs(info.lastScanDate.timeIntervalSince(newerFinishedAt)) < 1
        }
    }

    /// Rotation semantics: a content-identical rescan skips rotating the
    /// previous slot, so a target's first rescan leaves hasPreviousSnapshot
    /// false; only a rescan with different content produces a diffable
    /// predecessor. The optimistic index guess is corrected by the save's
    /// outcome.
    @Test func testUnchangedRescanLeavesHasPreviousSnapshotFalse() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/rotation")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel(policy: .automatic)

        // First scan: 10-byte file. No prior latest, so nothing rotates.
        model.startScan(target)
        var gen = model.session.kindStatsSidecarGeneration
        environment.scanService.yield(.finished(makeSnapshot(target: target, fileSize: 10)), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("first scan persisted") {
            model.session.kindStatsSidecarGeneration > gen
        }
        #expect(model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == false)

        // Second scan: identical content. The save keeps the (absent) previous
        // baseline instead of rotating, so hasPreviousSnapshot stays false.
        model.startScan(target)
        gen = model.session.kindStatsSidecarGeneration
        environment.scanService.yield(.finished(makeSnapshot(target: target, fileSize: 10)), scanIndex: 1)
        environment.scanService.finish(scanIndex: 1)
        try await waitUntilAsync("unchanged rescan persisted") {
            model.session.kindStatsSidecarGeneration > gen
        }
        #expect(model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == false)

        // Third scan: different content. Now the prior latest rotates into the
        // previous slot and a diffable predecessor exists.
        model.startScan(target)
        gen = model.session.kindStatsSidecarGeneration
        environment.scanService.yield(.finished(makeSnapshot(target: target, fileSize: 25)), scanIndex: 2)
        environment.scanService.finish(scanIndex: 2)
        try await waitUntilAsync("changed rescan rotates a previous snapshot") {
            model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }
    }

    /// After a scan finishes and persists, the kind-stats sidecar is written
    /// asynchronously and the generation counter bumps — the signal the
    /// sidebar's volume bars key on — and the sidecar then loads back.
    @Test func testKindStatsSidecarGenerationBumpsAndSidecarLoads() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/scan-life/sidecar")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel(policy: .automatic)

        model.startScan(target)
        environment.scanService.yield(.finished(makeSnapshot(target: target)), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)

        try await waitUntilAsync("sidecar generation bumped after persist") {
            model.session.kindStatsSidecarGeneration > 0
        }
        try await waitUntilAsync("sidecar loads back from disk") {
            await model.session.loadKindStatsSidecar(forTargetID: target.id) != nil
        }
    }

    // MARK: - Fixtures

    private struct TestEnvironment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let scanService: ControlledScanService
        let sidebarFolderStore: SidebarFolderStore
        let defaults: UserDefaults
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskScanLifeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledScanService()
            defaultsSuiteName = "NeodiskScanLifeTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            sidebarFolderStore = SidebarFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel(policy: AutoRescanPolicy? = nil) -> NeodiskViewModel {
            let model = NeodiskViewModel(
                coordinator: ScanCoordinator(
                    scanService: scanService,
                    progressThrottleDuration: .milliseconds(40)
                ),
                snapshotCache: cache,
                sidebarFolderStore: sidebarFolderStore
            )
            if let policy {
                let preferences = AppPreferences(defaults: defaults)
                preferences.autoRescanPolicy = policy
                model.preferences = preferences
            }
            return model
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }

    /// A one-file snapshot with a controllable file size (drives the content
    /// digest that governs cache rotation) and scan dates (drive the
    /// auto-rescan duration check).
    private func makeSnapshot(
        target: ScanTarget,
        fileSize: Int64 = 12,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) -> ScanSnapshot {
        let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: fileSize)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        return makeTestSnapshot(
            target: target,
            root: root,
            store: store,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}
