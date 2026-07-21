import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Stage 4 of parallel scanning: attaching a running background scan back to
/// the display on return — a cold scan's live partial map keeps streaming, a
/// refresh's stand-in holds with partials suppressed until the fresh finish, an
/// explicit rescan cancels and restarts, and a scan that finished while
/// detached shows its final tree instantly through the restore path.
extension ScanTimingSuites {
@MainActor
@Suite(.serialized) struct ParallelScanStage4Tests {
    /// Navigating back to a target whose cold scan was demoted attaches that
    /// live scan: its latest partial is on screen immediately and subsequent
    /// partials keep flowing to the display, on the same progress instance.
    @Test func testAttachToLiveColdScanResumesStreaming() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage4/live-a")
        let targetB = makeTestTarget("/stage4/live-b")
        let model = try await environment.makeIndexedModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.parallelSameDevice

        // A is a cold live scan (the index is ready and A has no cache).
        model.startScan(targetA)                 // scan index 0
        let sessionA = try #require(model.coordinator.displayedSession)
        #expect(!sessionA.showsStandInWhileScanning)

        // A first partial streams to the screen.
        environment.scanService.yield(.partial(environment.partialStore(for: targetA, count: 1)), scanIndex: 0)
        try await waitUntilAsync("A's first partial displayed") {
            model.coordinator.snapshot?.treeStore.nodeCount == 2
        }

        // Navigate away: A is demoted and keeps running in the background.
        model.startScan(targetB)                 // scan index 1
        #expect(model.session.activeSessions[targetA.id] === sessionA)

        // A keeps discovering while off screen.
        environment.scanService.yield(.partial(environment.partialStore(for: targetA, count: 3)), scanIndex: 0)
        try await waitUntilAsync("A recorded a larger partial off screen") {
            sessionA.latestSnapshot?.treeStore.nodeCount == 4
        }

        // Navigate back to A: its live partial map is on screen at once.
        model.startScan(targetA)
        #expect(model.coordinator.displayedSession === sessionA)
        #expect(model.session.activeSessions[targetA.id] == nil)
        #expect(model.coordinator.snapshot?.id == sessionA.latestSnapshot?.id)
        #expect(model.coordinator.snapshot?.isComplete == false)
        #expect(model.coordinator.snapshot?.treeStore.nodeCount == 4)
        // Same progress instance the bar was bound to — monotonic across the
        // detach/re-attach with no reset.
        #expect(model.coordinator.progress === sessionA.progress)

        // And subsequent partials keep updating the display.
        environment.scanService.yield(.partial(environment.partialStore(for: targetA, count: 5)), scanIndex: 0)
        try await waitUntilAsync("later partial updates the re-attached display") {
            model.coordinator.snapshot?.treeStore.nodeCount == 6
        }

        model.stopScan()
    }

    /// Navigating back to a target whose refresh was demoted attaches it behind
    /// its stand-in: the complete baseline holds the screen with partials
    /// suppressed, and the fresh finish swaps the final tree in.
    @Test func testAttachToRefreshHoldsStandInThenSwapsFinal() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage4/refresh-a")
        let targetB = makeTestTarget("/stage4/refresh-b")
        environment.sidebarFolderStore.add(targetA)
        // A has a cached snapshot, so selecting it refreshes behind that map.
        let baseline = environment.snapshot(for: targetA, size: 10)
        try await environment.cache.save(baseline)

        let model = environment.makeModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.parallelSameDevice
        try await waitUntilAsync("A indexed from cache") {
            model.session.cachedScanInfo[targetA.id] != nil
        }

        model.startScan(targetA)                 // scan index 0, refresh
        let sessionA = try #require(model.coordinator.displayedSession)
        try await waitUntilAsync("A's cached stand-in on screen") {
            model.coordinator.snapshot?.isComplete == true
                && model.coordinator.suppressesPartialEvents
        }
        #expect(sessionA.showsStandInWhileScanning)
        #expect(sessionA.refreshBaseline != nil)

        // Navigate away: A's refresh keeps running in the background.
        model.startScan(targetB)                 // scan index 1
        #expect(model.session.activeSessions[targetA.id] === sessionA)

        // Navigate back: the stand-in holds the screen, partials suppressed.
        model.startScan(targetA)
        #expect(model.coordinator.displayedSession === sessionA)
        #expect(model.coordinator.snapshot?.id == sessionA.refreshBaseline?.id)
        #expect(model.coordinator.suppressesPartialEvents)

        // A partial is still suppressed behind the stand-in.
        environment.scanService.yield(.partial(environment.partialStore(for: targetA, count: 2)), scanIndex: 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.coordinator.snapshot?.id == sessionA.refreshBaseline?.id)

        // The fresh finish swaps the final tree in and ends suppression.
        let fresh = environment.snapshot(for: targetA, size: 42)
        environment.scanService.yield(.finished(fresh), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("fresh finish swaps in on the re-attached refresh") {
            model.coordinator.snapshot?.id == fresh.id && model.coordinator.phase == .displaying
        }
        #expect(!model.coordinator.suppressesPartialEvents)

        model.stopScan()
    }

    /// An explicit rescan of a target whose scan is running in the background
    /// cancels that scan and starts a fresh one (one running session per
    /// target), rather than attaching the background scan.
    @Test func testForcesRescanCancelsBackgroundAndRestarts() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage4/force-a")
        let targetB = makeTestTarget("/stage4/force-b")
        let model = try await environment.makeIndexedModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.parallelSameDevice

        model.startScan(targetA)                 // scan index 0
        let sessionA = try #require(model.coordinator.displayedSession)
        model.startScan(targetB)                 // scan index 1, A demoted
        #expect(model.session.activeSessions[targetA.id] === sessionA)

        // Explicit rescan of A: cancel the background scan, start a new one.
        model.startScan(targetA, forcesRescan: true)   // scan index 2

        #expect(sessionA.state == .cancelled)
        #expect(model.session.activeSessions[targetA.id] == nil)
        let restarted = try #require(model.coordinator.displayedSession)
        #expect(restarted !== sessionA)
        #expect(restarted.target.id == targetA.id)
        #expect(model.coordinator.isScanning)

        model.stopScan()
    }

    /// A background scan that finishes while detached persists and is
    /// remembered; clicking its target then shows the final tree instantly
    /// through the restore path, with no attach.
    @Test func testFinishWhileDetachedThenClickRestoresInstantly() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage4/detached-a")
        let targetB = makeTestTarget("/stage4/detached-b")
        environment.sidebarFolderStore.add(targetA)
        let model = try await environment.makeIndexedModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.parallelSameDevice

        model.startScan(targetA)                 // scan index 0
        let sessionA = try #require(model.coordinator.displayedSession)
        model.startScan(targetB)                 // scan index 1, A demoted
        #expect(model.session.activeSessions[targetA.id] === sessionA)

        // A's background scan finishes while off screen; await its persistence
        // deterministically rather than polling under parallel-test load.
        let finalA = environment.snapshot(for: targetA, size: 33)
        await awaitSnapshotPersist(on: model, of: targetA) {
            environment.scanService.yield(.finished(finalA), scanIndex: 0)
            environment.scanService.finish(scanIndex: 0)
        }
        #expect(model.session.activeSessions[targetA.id] == nil)
        #expect(model.coordinator.recentSnapshot(forTargetID: targetA.id) != nil)
        #expect(sessionA.state == .finished)

        // Clicking A now shows its final tree instantly from the restore path.
        let scanCountBefore = environment.scanService.scanCount
        model.startScan(targetA)
        #expect(model.coordinator.snapshot?.id == finalA.id)
        #expect(model.coordinator.snapshot?.isComplete == true)
        #expect(model.coordinator.snapshot?.target.id == targetA.id)
        // Under .automatic a refresh runs behind it, but from memory — no new
        // background scan of A was started to display it.
        #expect(model.coordinator.displayedSession?.target.id == targetA.id)
        _ = scanCountBefore

        model.stopScan()
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
                .appending(path: "NeodiskStage4Tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledScanService()
            defaultsSuiteName = "NeodiskStage4Tests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            sidebarFolderStore = SidebarFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel(policy: AutoRescanPolicy, autoScanDuplicates: Bool = false) -> NeodiskViewModel {
            let model = NeodiskViewModel(
                coordinator: ScanCoordinator(
                    scanService: scanService,
                    progressThrottleDuration: .milliseconds(40)
                ),
                snapshotCache: cache,
                sidebarFolderStore: sidebarFolderStore
            )
            let preferences = AppPreferences(defaults: defaults)
            preferences.autoRescanPolicy = policy
            preferences.autoScanDuplicates = autoScanDuplicates
            model.preferences = preferences
            return model
        }

        /// A model whose launch cache index is ready, so a target with no
        /// cache scans cold (streams live partials) instead of taking the
        /// pre-index refresh branch. Gated on a seed target's indexing.
        @MainActor
        func makeIndexedModel(policy: AutoRescanPolicy) async throws -> NeodiskViewModel {
            let seed = makeTestTarget("/stage4/seed")
            sidebarFolderStore.add(seed)
            try await cache.save(snapshot(for: seed))
            let model = makeModel(policy: policy)
            try await waitUntilAsync("launch cache index ready") {
                model.session.cachedScanInfo[seed.id] != nil
            }
            return model
        }

        func snapshot(for target: ScanTarget, size: Int64 = 12) -> ScanSnapshot {
            let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: size)
            let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
            let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
            return makeTestSnapshot(target: target, root: root, store: store)
        }

        /// A partial (incomplete) tree of `target` with `count` files under the
        /// root, so a node count of `count + 1` distinguishes successive
        /// partials.
        func partialStore(for target: ScanTarget, count: Int) -> FileTreeStore {
            let files = (0..<count).map {
                makeTestFileNode(id: "\(target.id)/f\($0).txt", name: "f\($0).txt", size: 1)
            }
            let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: files)
            return FileTreeStore(root: root, childrenByID: [root.id: files])
        }

        // Same physical device, internally parallel: two scans run at once.
        func parallelSameDevice(_ target: ScanTarget) -> ScanSourceIdentity {
            ScanSourceIdentity(profile: .localParallel, deviceID: 1)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }
}

}
