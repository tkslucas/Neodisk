import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Stage 2 of parallel scanning: the navigate-away ruling (run both / cancel /
/// defer), the background-session registry and its completion, the model-level
/// guards, and the diff-rotation isolation a background save must respect.
extension ScanTimingSuites {
@MainActor
@Suite(.serialized) struct ParallelScanStage2Tests {
    /// Leaving a running scan for a target on a different (non-contended) disk
    /// keeps the old scan running in the background and displays the new one.
    @Test func testNavigateAwayDemotesRunningScanToBackground() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage2/demote-a")
        let targetB = makeTestTarget("/stage2/demote-b")
        let model = environment.makeModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.parallelSameDevice

        model.startScan(targetA)
        let sessionA = try #require(model.coordinator.displayedSession)
        #expect(sessionA.target.id == targetA.id)

        model.startScan(targetB)

        // A keeps running in the background registry; B is now on screen.
        #expect(model.session.activeSessions[targetA.id] === sessionA)
        #expect(model.session.activeSession(forTargetID: targetA.id)?.state == .running)
        #expect(model.coordinator.displayedSession?.target.id == targetB.id)
        #expect(model.coordinator.selectedTarget?.id == targetB.id)
        #expect(sessionA.state == .running)

        model.session.stopSession(forTargetID: targetA.id)
        model.stopScan()
    }

    /// A background scan finishing persists like a foreground one (cache index,
    /// sidecar generation, recent-snapshot LRU) but never touches the displayed
    /// tree and never runs the on-screen conveniences.
    @Test func testBackgroundScanFinishPersistsAndInsertsLRUWithoutTouchingDisplay() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage2/bg-a")
        let targetB = makeTestTarget("/stage2/bg-b")
        // Duplicates auto-scan on: a foreground finish would start it; a
        // background finish must not.
        let model = environment.makeModel(policy: .automatic, autoScanDuplicates: true)
        model.session.sourceIdentityProvider = environment.parallelSameDevice

        model.startScan(targetA)          // scan index 0
        let sessionA = try #require(model.coordinator.displayedSession)
        model.startScan(targetB)          // scan index 1, A demoted to background

        let generationBefore = model.session.kindStatsSidecarGeneration

        // Finish A's background scan and await its persistence deterministically.
        await awaitSnapshotPersist(on: model, of: targetA) {
            environment.scanService.yield(.finished(environment.snapshot(for: targetA)), scanIndex: 0)
            environment.scanService.finish(scanIndex: 0)
        }

        // Left the registry, persisted through the shared path (cache index +
        // sidecar generation bumped), and remembered for an instant return.
        #expect(model.session.activeSessions[targetA.id] == nil)
        #expect(model.session.cachedScanInfo[targetA.id] != nil)
        #expect(model.session.kindStatsSidecarGeneration > generationBefore)
        #expect(model.coordinator.recentSnapshot(forTargetID: targetA.id) != nil)

        // The display is still B, and the on-screen conveniences never ran.
        #expect(model.coordinator.selectedTarget?.id == targetB.id)
        #expect(model.coordinator.snapshot?.target.id != targetA.id)
        #expect(!model.duplicates.isScanning)
        #expect(sessionA.state == .finished)

        model.stopScan()
    }

    /// An explicit scan on the same contended disk stops the running scan and
    /// leaves a passive mention naming what was stopped.
    @Test func testExplicitScanOnContendedDiskCancelsRunningAndEmitsNotice() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage2/cancel-a")
        let targetB = makeTestTarget("/stage2/cancel-b")
        let model = environment.makeModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.conservativeSameDevice

        model.startScan(targetA)
        let sessionA = try #require(model.coordinator.displayedSession)

        // Explicit selection of B on the same conservative disk.
        model.startScan(targetB, forcesRescan: true)

        #expect(sessionA.state == .cancelled)
        #expect(model.session.activeSessions[targetA.id] == nil)
        #expect(model.coordinator.displayedSession?.target.id == targetB.id)
        #expect(model.session.supersededScanNotice?.displayName == targetA.displayName)

        model.stopScan()
    }

    /// An implicit refresh on the same contended disk defers to the running
    /// scan: the new target shows from cache with the manual-rescan notice, no
    /// second scan starts, and the running scan keeps going in the background.
    @Test func testImplicitRefreshOnContendedDiskDefersAndShowsCache() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/stage2/defer-a")
        let targetB = makeTestTarget("/stage2/defer-b")
        environment.sidebarFolderStore.add(targetB)
        // B has a cached snapshot to stand in.
        try await environment.cache.save(environment.snapshot(for: targetB))

        let model = environment.makeModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.conservativeSameDevice
        try await waitUntilAsync("B indexed from cache") {
            model.session.cachedScanInfo[targetB.id] != nil
        }

        model.startScan(targetA)          // scan index 0, running
        let sessionA = try #require(model.coordinator.displayedSession)
        let scanCountBefore = environment.scanService.scanCount

        model.startScan(targetB)          // implicit; must defer

        try await waitUntilAsync("B shown from cache with the manual-rescan notice") {
            model.session.snapshotNotice?.targetID == targetB.id
                && model.coordinator.snapshot?.target.id == targetB.id
                && model.coordinator.snapshot?.isComplete == true
        }
        // No refresh scan of B was started, and A is still running in the
        // background.
        #expect(environment.scanService.scanCount == scanCountBefore)
        #expect(model.session.activeSession(forTargetID: targetA.id)?.state == .running)
        #expect(sessionA.state == .running)
        #expect(model.session.supersededScanNotice == nil)

        model.session.stopSession(forTargetID: targetA.id)
    }

    /// A background save's diff-rotation notification is scoped to the target
    /// it rotated: a displayed diff of a DIFFERENT target is untouched.
    @Test func testRotationNotificationForAnotherTargetLeavesDisplayedDiffAlone() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let displayedTarget = makeTestTarget("/stage2/diff-displayed")
        let backgroundTarget = makeTestTarget("/stage2/diff-background")
        // Kept in the sidebar so the launch prune preserves its cache.
        environment.sidebarFolderStore.add(displayedTarget)
        // Two generations for the displayed target so it has a diffable
        // predecessor on disk.
        try await environment.cache.save(environment.snapshot(for: displayedTarget, size: 10))
        let latest = environment.snapshot(for: displayedTarget, size: 25)
        try await environment.cache.save(latest)

        let model = environment.makeModel(policy: .automatic)
        try await waitUntilAsync("displayed target indexed with a predecessor") {
            model.session.cachedScanInfo[displayedTarget.id]?.hasPreviousSnapshot == true
        }

        // Put the latest snapshot on screen and open the Changes tab so the
        // baseline loads.
        model.coordinator.restoreCompletedSnapshot(latest)
        model.showKindStats = true
        model.analysisTab = .changes
        try await waitUntilAsync("diff baseline loaded for the displayed target") {
            model.diff.isShowing
        }
        let baselineBefore = model.diff.baseline
        let reloadTokenBefore = model.changes.reloadToken

        // A background save of the OTHER target rotates its predecessor; the
        // guard keys on the displayed target, so nothing here changes.
        model.diff.snapshotWasRotated(for: backgroundTarget)
        model.changes.snapshotWasRotated(for: backgroundTarget)

        #expect(model.diff.isShowing)
        #expect(model.diff.baseline?.targetID == baselineBefore?.targetID)
        #expect(model.changes.reloadToken == reloadTokenBefore)
    }

    /// A location with a scan in flight can't be removed from the sidebar or
    /// signed out from under the running session.
    @Test func testRemoveSidebarFolderRefusesRunningTarget() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/stage2/guard-folder")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel(policy: .automatic)
        model.session.sourceIdentityProvider = environment.parallelSameDevice

        model.startScan(target)
        #expect(model.session.activeSession(forTargetID: target.id)?.state == .running)

        model.removeSidebarFolders(ids: [target.id])
        // Refused while scanning.
        #expect(model.sidebarFolders.contains { $0.id == target.id })

        model.stopScan()
        model.removeSidebarFolders(ids: [target.id])
        // Removable once the scan is no longer running.
        #expect(!model.sidebarFolders.contains { $0.id == target.id })
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
                .appending(path: "NeodiskStage2Tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledScanService()
            defaultsSuiteName = "NeodiskStage2Tests-\(UUID().uuidString)"
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

        func snapshot(for target: ScanTarget, size: Int64 = 12) -> ScanSnapshot {
            let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: size)
            let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
            let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
            return makeTestSnapshot(target: target, root: root, store: store)
        }

        // Same physical device, internally parallel: two scans run at once.
        func parallelSameDevice(_ target: ScanTarget) -> ScanSourceIdentity {
            ScanSourceIdentity(profile: .localParallel, deviceID: 1)
        }

        // Same physical device, conservative: scans serialize on the disk.
        func conservativeSameDevice(_ target: ScanTarget) -> ScanSourceIdentity {
            ScanSourceIdentity(profile: .localConservative, deviceID: 1)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }
}

}
