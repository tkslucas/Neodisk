import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Snapshot-cache wiring in the view model: persisting finished scans,
/// restoring cached ones, and deleting a pinned folder's snapshot with it.
@MainActor
@Suite(.serialized) struct NeodiskViewModelSnapshotCacheTests {
    @Test func testRemovingPinnedFolderDeletesItsPersistedSnapshot() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/pinned")
        environment.pinnedFolderStore.add(target)
        try await environment.cache.save(makeSimpleSnapshot(target: target))

        let model = environment.makeModel()
        try await waitUntilAsync("prune indexes the pinned snapshot") {
            model.cachedScanInfo[target.id] != nil
        }

        model.removePinnedFolders(ids: [target.id])

        #expect(model.cachedScanInfo[target.id] == nil)
        #expect(model.pinnedFolders.isEmpty)
        try await waitUntilAsync("snapshot file deleted") {
            await environment.cache.loadSnapshot(for: target) == nil
        }
    }

    @Test func testLaunchPruneDropsSnapshotsForUnknownLocations() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let orphan = makeTestTarget("/cache-vm/orphan")
        try await environment.cache.save(makeSimpleSnapshot(target: orphan))

        let model = environment.makeModel()

        try await waitUntilAsync("orphan snapshot pruned") {
            await environment.cache.loadSnapshot(for: orphan) == nil
        }
        #expect(model.cachedScanInfo[orphan.id] == nil)
    }

    @Test func testFinishedScanIsPersistedAndRestoredOnNextSelection() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/scanned")
        environment.pinnedFolderStore.add(target)
        let model = environment.makeModel()

        model.startScan(target)
        let finished = makeSimpleSnapshot(target: target)
        environment.scanService.yield(.finished(finished), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)

        try await waitUntilAsync("scan persisted to cache") {
            await environment.cache.loadSnapshot(for: target) != nil
        }
        #expect(model.cachedScanInfo[target.id] != nil)

        // Move away, then reselect: the cached snapshot must appear while
        // the refresh scan is still running, with partials suppressed.
        let elsewhere = makeTestTarget("/cache-vm/elsewhere")
        model.startScan(elsewhere)
        model.startScan(target)

        try await waitUntilAsync("cached snapshot displayed during refresh") {
            model.coordinator.isScanning && model.coordinator.snapshot?.isComplete == true
        }
        #expect(model.coordinator.snapshot?.target.id == target.id)
        #expect(model.coordinator.displayedCachedScanDate != nil)
        model.stopScan()
    }

    @Test func testSlowLocationOpensSnapshotWithoutAutoRescan() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/slow")
        environment.pinnedFolderStore.add(target)
        // The last scan took four minutes — far past the auto-rescan
        // threshold, so selecting the target must show the snapshot and
        // leave rescanning to the user.
        try await environment.cache.save(makeSimpleSnapshot(
            target: target,
            startedAt: Date(timeIntervalSinceNow: -300),
            finishedAt: Date(timeIntervalSinceNow: -60)
        ))

        let model = environment.makeModel()
        try await waitUntilAsync("prune indexes the slow snapshot") {
            model.cachedScanInfo[target.id] != nil
        }

        model.startScan(target)

        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }
        #expect(!model.coordinator.isScanning)
        #expect(model.coordinator.snapshot?.target.id == target.id)
        #expect(model.snapshotNotice?.targetID == target.id)
        #expect(environment.scanService.scanCount == 0)

        // A sidebar re-click on the undecided snapshot must not sneak the
        // skipped rescan in.
        model.startScan(target)
        #expect(environment.scanService.scanCount == 0)
        #expect(model.coordinator.phase == .displaying)

        // The explicit rescan clears the notice and refreshes behind the map.
        model.rescan()
        #expect(model.snapshotNotice == nil)
        #expect(model.coordinator.isScanning)
        #expect(environment.scanService.scanCount == 1)
        model.stopScan()
    }

    @Test func testSnapshotOnlyPolicyShowsFastSnapshotWithoutRescan() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/fast-snapshot-only")
        environment.pinnedFolderStore.add(target)
        // The last scan was instantaneous — smart would auto-rescan this,
        // but the snapshot-only policy must still display the snapshot and
        // leave rescanning to the notice or the toolbar.
        try await environment.cache.save(makeSimpleSnapshot(target: target))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the fast snapshot") {
            model.cachedScanInfo[target.id] != nil
        }

        model.startScan(target)

        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }
        #expect(!model.coordinator.isScanning)
        #expect(model.coordinator.snapshot?.target.id == target.id)
        #expect(model.snapshotNotice?.targetID == target.id)
        #expect(environment.scanService.scanCount == 0)

        // Re-clicking the sidebar row must not sneak the skipped rescan in;
        // the explicit rescan still works and clears the notice.
        model.startScan(target)
        #expect(environment.scanService.scanCount == 0)
        model.rescan()
        #expect(model.snapshotNotice == nil)
        #expect(model.coordinator.isScanning)
        #expect(environment.scanService.scanCount == 1)
        model.stopScan()
    }

    @Test func testAutomaticPolicyAutoRescansSlowLocationWithoutNotice() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/slow-automatic")
        environment.pinnedFolderStore.add(target)
        // Four-minute last scan — smart would go snapshot-only, but the
        // automatic policy refreshes behind the cached snapshot, and the
        // decode-completion race check must not cancel that refresh.
        try await environment.cache.save(makeSimpleSnapshot(
            target: target,
            startedAt: Date(timeIntervalSinceNow: -300),
            finishedAt: Date(timeIntervalSinceNow: -60)
        ))

        let model = environment.makeModel(policy: .automatic)
        try await waitUntilAsync("prune indexes the slow snapshot") {
            model.cachedScanInfo[target.id] != nil
        }

        model.startScan(target)

        try await waitUntilAsync("cached snapshot displayed during refresh") {
            model.coordinator.isScanning && model.coordinator.snapshot?.isComplete == true
        }
        #expect(model.coordinator.snapshot?.target.id == target.id)
        #expect(model.coordinator.displayedCachedScanDate != nil)
        #expect(model.snapshotNotice == nil)
        #expect(environment.scanService.scanCount == 1)
        model.stopScan()
    }

    @Test func testScanDiffComparesAgainstRotatedPreviousSnapshot() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/diffed")
        environment.pinnedFolderStore.add(target)
        let model = environment.makeModel()

        // First scan: the file is 10 bytes.
        model.startScan(target)
        environment.scanService.yield(
            .finished(makeSizedSnapshot(target: target, fileSize: 10)),
            scanIndex: 0
        )
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("first scan persisted") {
            await environment.cache.loadSnapshot(for: target) != nil
        }
        #expect(!model.diff.canShow)

        // Second scan: the file grew to 25 bytes; the first snapshot
        // rotates into the previous slot.
        model.rescan()
        environment.scanService.yield(
            .finished(makeSizedSnapshot(target: target, fileSize: 25)),
            scanIndex: 1
        )
        environment.scanService.finish(scanIndex: 1)
        try await waitUntilAsync("previous snapshot available") {
            model.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }

        #expect(model.diff.canShow)
        model.diff.toggle()
        try await waitUntilAsync("baseline loaded") {
            model.diff.baseline != nil
        }

        let baseline = try #require(model.diff.baseline)
        let fileID = target.id + "/file.txt"
        #expect(baseline.allocatedSize(forNodeID: fileID) == 10)
        let displayedFile = try #require(model.store?.node(id: fileID))
        #expect(baseline.sizeDelta(for: displayedFile) == 15)

        model.diff.toggle()
        #expect(model.diff.baseline == nil)
    }

    @Test func testDiffBaselinePrefetchesAfterSecondScanAndTogglesInstantly() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/prefetched")
        environment.pinnedFolderStore.add(target)
        let model = environment.makeModel()
        // Collapse the restore/rotate prefetch delay: this test asserts on
        // the prefetch result, not the first-paint deferral.
        model.diff.prefetchDelay = .zero

        // First scan: only one snapshot exists, so there is nothing to
        // prefetch a baseline from.
        model.startScan(target)
        environment.scanService.yield(
            .finished(makeSizedSnapshot(target: target, fileSize: 10)),
            scanIndex: 0
        )
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("first scan persisted") {
            await environment.cache.loadSnapshot(for: target) != nil
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.diff.prefetchedBaseline == nil)
        #expect(!model.diff.isLoading)

        // Second scan: rotation makes a previous snapshot, and the default
        // "prepare Changes" preference prefetches its baseline unasked.
        model.rescan()
        environment.scanService.yield(
            .finished(makeSizedSnapshot(target: target, fileSize: 25)),
            scanIndex: 1
        )
        environment.scanService.finish(scanIndex: 1)
        try await waitUntilAsync("baseline prefetched") {
            model.diff.prefetchedBaseline != nil
        }
        #expect(!model.diff.isLoading)
        #expect(!model.diff.isShowing)

        // The toggle must not need another load: the baseline shows
        // synchronously and carries the previous scan's sizes.
        model.diff.toggle()
        let baseline = try #require(model.diff.baseline)
        #expect(baseline.allocatedSize(forNodeID: target.id + "/file.txt") == 10)
    }

    @Test func testAutoDuplicateScanPreferenceStartsScanAfterFinish() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/auto-duplicates")
        environment.pinnedFolderStore.add(target)
        let model = environment.makeModel()
        let preferences = AppPreferences(defaults: environment.defaults)
        preferences.autoScanDuplicates = true
        model.preferences = preferences

        model.startScan(target)
        environment.scanService.yield(.finished(makeSimpleSnapshot(target: target)), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)

        // The single-file snapshot has no duplicate candidates, so the
        // auto-started scan finishes immediately with empty results — the
        // point is that it ran without a click.
        try await waitUntilAsync("duplicate scan auto-started and finished") {
            model.duplicates.results != nil
        }
        #expect(model.duplicates.results?.groups.isEmpty == true)
    }

    @Test func testDuplicateScanStaysIdleWithoutAutoScanPreference() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/manual-duplicates")
        environment.pinnedFolderStore.add(target)
        let model = environment.makeModel()

        model.startScan(target)
        environment.scanService.yield(.finished(makeSimpleSnapshot(target: target)), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("scan persisted to cache") {
            await environment.cache.loadSnapshot(for: target) != nil
        }

        guard case .idle = model.duplicates.phase else {
            Issue.record("Duplicate scan ran without the opt-in preference.")
            return
        }
    }

    @Test func testSnapshotOnlyRestorePrefetchesDiffBaseline() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/restore-prefetch")
        environment.pinnedFolderStore.add(target)
        // Two generations on disk: opening the snapshot without a rescan
        // must still prefetch the baseline from the rotated previous scan.
        try await environment.cache.save(makeSizedSnapshot(target: target, fileSize: 10))
        try await environment.cache.save(makeSizedSnapshot(target: target, fileSize: 25))

        let model = environment.makeModel(policy: .snapshotOnly)
        // Collapse the restore prefetch delay: this test asserts on the
        // prefetch result, not the first-paint deferral.
        model.diff.prefetchDelay = .zero
        try await waitUntilAsync("prune indexes the snapshot with a previous") {
            model.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }

        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }
        #expect(environment.scanService.scanCount == 0)

        try await waitUntilAsync("baseline prefetched after restore") {
            model.diff.prefetchedBaseline != nil
        }
        #expect(!model.diff.isShowing)

        // The toggle must not need another load: the baseline shows
        // synchronously and carries the previous scan's sizes.
        model.diff.toggle()
        let baseline = try #require(model.diff.baseline)
        #expect(baseline.allocatedSize(forNodeID: target.id + "/file.txt") == 10)
    }

    @Test func testSnapshotOnlyRestoreStartsAutoDuplicateScan() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/restore-duplicates")
        environment.pinnedFolderStore.add(target)
        try await environment.cache.save(makeSimpleSnapshot(target: target))

        let model = environment.makeModel(policy: .snapshotOnly)
        model.preferences?.autoScanDuplicates = true
        try await waitUntilAsync("prune indexes the snapshot") {
            model.cachedScanInfo[target.id] != nil
        }

        model.startScan(target)

        // The single-file snapshot has no duplicate candidates, so the
        // auto-started scan finishes immediately with empty results — the
        // point is that opening the snapshot ran it without a click.
        try await waitUntilAsync("duplicate scan auto-started and finished") {
            model.duplicates.results != nil
        }
        #expect(environment.scanService.scanCount == 0)
        #expect(model.duplicates.results?.groups.isEmpty == true)
    }

    @Test func testRestoreRunsNoConveniencesWithPreferencesOff() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/cache-vm/restore-opted-out")
        environment.pinnedFolderStore.add(target)
        try await environment.cache.save(makeSizedSnapshot(target: target, fileSize: 10))
        try await environment.cache.save(makeSizedSnapshot(target: target, fileSize: 25))

        let model = environment.makeModel(policy: .snapshotOnly)
        model.preferences?.prepareChangesAfterScan = false
        try await waitUntilAsync("prune indexes the snapshot with a previous") {
            model.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }

        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(model.diff.prefetchedBaseline == nil)
        #expect(!model.diff.isLoading)
        guard case .idle = model.duplicates.phase else {
            Issue.record("Duplicate scan ran without the opt-in preference.")
            return
        }
    }

    // MARK: - Fixtures

    private struct TestEnvironment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let scanService: ControlledCacheScanService
        let pinnedFolderStore: PinnedFolderStore
        let defaults: UserDefaults
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskVMCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledCacheScanService()
            defaultsSuiteName = "NeodiskVMCacheTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            pinnedFolderStore = PinnedFolderStore(defaults: defaults)
        }

        /// Models get preferences the same way the app injects them
        /// (ContentView assigns model.preferences once on appear), backed by
        /// this environment's isolated defaults suite.
        @MainActor
        func makeModel(policy: AutoRescanPolicy? = nil) -> NeodiskViewModel {
            let model = NeodiskViewModel(
                coordinator: ScanCoordinator(
                    scanService: scanService,
                    progressThrottleDuration: .milliseconds(40)
                ),
                snapshotCache: cache,
                pinnedFolderStore: pinnedFolderStore
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

    private func makeSizedSnapshot(target: ScanTarget, fileSize: Int64) -> ScanSnapshot {
        let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: fileSize)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        return makeTestSnapshot(target: target, root: root, store: store)
    }

    private func makeSimpleSnapshot(
        target: ScanTarget,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) -> ScanSnapshot {
        let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: 12)
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

/// Same shape as ScanCoordinatorTests' controlled service, local to this
/// suite because that one is file-private.
private final class ControlledCacheScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func yield(_ event: ScanProgressEvent, scanIndex: Int) {
        continuation(at: scanIndex)?.yield(event)
    }

    func finish(scanIndex: Int, throwing error: Error? = nil) {
        continuation(at: scanIndex)?.finish(throwing: error)
    }

    private func continuation(at index: Int) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.indices.contains(index) else { return nil }
        return continuations[index]
    }
}

@MainActor
private func waitUntilAsync(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() >= deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
