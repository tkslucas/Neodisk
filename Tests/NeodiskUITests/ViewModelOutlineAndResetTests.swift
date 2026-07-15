import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Characterization tests pinning the view model's outline flattening, its
/// per-scan state reset, warning-dismissal reset on rescan, and the
/// stop/resume lifecycle — the behavior a coming refactor must preserve.
@MainActor
@Suite(.serialized) struct ViewModelOutlineAndResetTests {

    // MARK: - Outline rows

    /// root ─┬─ dirA ─┬─ file1.bin (100)
    ///       │        └─ file2.bin (50)
    ///       ├─ dirB ── file3.bin (30)
    ///       └─ file4.bin (10)
    /// Sizes chosen so the size-descending sibling order is stable and
    /// distinct at every level.
    private func makeMultiLevelSnapshot(target: ScanTarget) -> ScanSnapshot {
        let file1 = makeTestFileNode(id: target.id + "/dirA/file1.bin", name: "file1.bin", size: 100)
        let file2 = makeTestFileNode(id: target.id + "/dirA/file2.bin", name: "file2.bin", size: 50)
        let dirA = makeTestDirectoryNode(id: target.id + "/dirA", name: "dirA", children: [file1, file2])
        let file3 = makeTestFileNode(id: target.id + "/dirB/file3.bin", name: "file3.bin", size: 30)
        let dirB = makeTestDirectoryNode(id: target.id + "/dirB", name: "dirB", children: [file3])
        let file4 = makeTestFileNode(id: target.id + "/file4.bin", name: "file4.bin", size: 10)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [dirA, dirB, file4])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [dirA, dirB, file4],
                dirA.id: [file1, file2],
                dirB.id: [file3],
            ]
        )
        return makeTestSnapshot(target: target, root: root, store: store)
    }

    @Test func testVisibleOutlineRowsFlattensExpandedTreeDepthFirst() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/multi")
        let model = environment.makeModel()

        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))

        // snapshotDidChange auto-expands the root row, so its children show at
        // depth 1 (size-descending: dirA, dirB, file4). Collapsed dirs hide
        // their own children.
        let collapsed = model.visibleOutlineRows()
        #expect(collapsed.map(\.id) == [
            target.id,
            target.id + "/dirA",
            target.id + "/dirB",
            target.id + "/file4.bin",
        ])
        #expect(collapsed.map(\.depth) == [0, 1, 1, 1])
        // Only directories that actually have children are expandable.
        #expect(collapsed.first { $0.id == target.id }?.isExpandable == true)
        #expect(collapsed.first { $0.id == target.id + "/dirA" }?.isExpandable == true)
        #expect(collapsed.first { $0.id == target.id + "/dirB" }?.isExpandable == true)
        #expect(collapsed.first { $0.id == target.id + "/file4.bin" }?.isExpandable == false)

        // Expanding dirA slots its children in depth-first, right after dirA's
        // own row and before its sibling dirB.
        model.toggleExpansion(target.id + "/dirA")
        let expanded = model.visibleOutlineRows()
        #expect(expanded.map(\.id) == [
            target.id,
            target.id + "/dirA",
            target.id + "/dirA/file1.bin",
            target.id + "/dirA/file2.bin",
            target.id + "/dirB",
            target.id + "/file4.bin",
        ])
        #expect(expanded.map(\.depth) == [0, 1, 2, 2, 1, 1])

        // Collapsing again removes exactly dirA's children.
        model.toggleExpansion(target.id + "/dirA")
        #expect(model.visibleOutlineRows().map(\.id) == collapsed.map(\.id))
    }

    @Test func testToggleExpansionRoundTripsExpandedSet() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/toggle")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))

        // The root arrives already expanded; toggling removes it, toggling
        // again re-inserts it.
        #expect(model.expandedNodeIDs.contains(target.id))
        model.toggleExpansion(target.id)
        #expect(!model.expandedNodeIDs.contains(target.id))
        model.toggleExpansion(target.id)
        #expect(model.expandedNodeIDs.contains(target.id))

        // A fresh id inserts then removes.
        let dirA = target.id + "/dirA"
        #expect(!model.expandedNodeIDs.contains(dirA))
        model.toggleExpansion(dirA)
        #expect(model.expandedNodeIDs.contains(dirA))
        model.toggleExpansion(dirA)
        #expect(!model.expandedNodeIDs.contains(dirA))
    }

    @Test func testOutlineSiblingOrderingFollowsDiffMagnitudeWhenBaselinePresent() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/diffed")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel()

        // First scan is the baseline; second scan changes the three files by
        // +1, −20, +5. The previous snapshot rotates into the diff baseline.
        model.startScan(target)
        environment.scanService.yield(
            .finished(makeThreeFileSnapshot(target: target, sizes: [10, 30, 10])),
            scanIndex: 0
        )
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("first scan persisted") {
            await environment.cache.loadSnapshot(for: target) != nil
        }

        model.rescan()
        environment.scanService.yield(
            .finished(makeThreeFileSnapshot(target: target, sizes: [11, 10, 15])),
            scanIndex: 1
        )
        environment.scanService.finish(scanIndex: 1)
        try await waitUntilAsync("previous snapshot available") {
            model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }

        // Opening the Changes tab arms the diff; siblings then order by
        // |sizeDelta| descending: file2(−20), file3(+5), file1(+1).
        model.analysisTab = .changes
        try await waitUntilAsync("baseline loaded") {
            model.diff.baseline != nil
        }
        let diffOrder = model.visibleOutlineRows()
            .filter { $0.id != target.id }
            .map(\.id)
        #expect(diffOrder == [
            target.id + "/file2.txt",
            target.id + "/file3.txt",
            target.id + "/file1.txt",
        ])

        // Leaving the tab drops the baseline; ordering reverts to the store's
        // own size-descending order: file3(15), file1(11), file2(10).
        model.analysisTab = .largest
        #expect(model.diff.baseline == nil)
        let storeOrder = model.visibleOutlineRows()
            .filter { $0.id != target.id }
            .map(\.id)
        #expect(storeOrder == [
            target.id + "/file3.txt",
            target.id + "/file1.txt",
            target.id + "/file2.txt",
        ])
    }

    // MARK: - Per-scan state reset

    @Test func testStartScanOfNewTargetResetsPerScanState() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let targetA = makeTestTarget("/reset/a")
        let targetB = makeTestTarget("/reset/b")
        let model = environment.makeModel()

        // Display a finished scan of A.
        model.startScan(targetA)
        let warning = ScanWarning(path: "/reset/a/skip", message: "skipped", category: .fileSystem)
        let file = makeTestFileNode(id: targetA.id + "/file.txt", name: "file.txt", size: 12)
        let root = makeTestDirectoryNode(id: targetA.id, name: targetA.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        environment.scanService.yield(
            .finished(makeTestSnapshot(target: targetA, root: root, store: store, warnings: [warning])),
            scanIndex: 0
        )
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("scan A persisted") {
            model.session.cachedScanInfo[targetA.id] != nil
        }

        // Dirty every axis the reset is supposed to clear.
        model.selectedNodeID = file.id
        model.hoveredNodeID = file.id
        model.zoomRootID = targetA.id
        model.expandedAggregateIDs = [targetA.id]
        model.warnings.dismiss(warning.id)
        model.stopScan()
        #expect(model.scanWasStopped)

        // Scanning a DIFFERENT target wipes selection/hover/zoom, empties the
        // expanded sets, clears dismissed warnings, and unsets scanWasStopped.
        model.startScan(targetB)
        #expect(model.selectedNodeID == nil)
        #expect(model.hoveredNodeID == nil)
        #expect(model.zoomRootID == nil)
        #expect(model.expandedNodeIDs.isEmpty)
        #expect(model.expandedAggregateIDs.isEmpty)
        #expect(model.warnings.dismissedWarningIDs.isEmpty)
        #expect(!model.scanWasStopped)
        model.stopScan()
    }

    @Test func testDismissedWarningsResurfaceOnRescan() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/reset/warnings")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel()

        let warningA = ScanWarning(path: "/reset/warnings/one", message: "skipped", category: .fileSystem)
        let warningB = ScanWarning(path: "/reset/warnings/two", message: "skipped", category: .fileSystem)
        let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: 12)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        func warned() -> ScanSnapshot {
            makeTestSnapshot(target: target, root: root, store: store, warnings: [warningA, warningB])
        }

        model.startScan(target)
        environment.scanService.yield(.finished(warned()), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("scan persisted") {
            await environment.cache.loadSnapshot(for: target) != nil
        }
        #expect(model.warnings.visible.count == 2)

        // Dismissing one shrinks the panel; dismissing all empties it.
        model.warnings.dismiss(warningA.id)
        #expect(model.warnings.visible.map(\.id) == [warningB.id])
        model.warnings.dismissAll()
        #expect(model.warnings.visible.isEmpty)

        // A rescan resets the dismissals, so the same still-current warnings
        // come back once the refreshed snapshot lands.
        model.rescan()
        environment.scanService.yield(.finished(warned()), scanIndex: 1)
        environment.scanService.finish(scanIndex: 1)
        try await waitUntilAsync("warnings resurfaced after rescan") {
            model.warnings.visible.count == 2
        }
        #expect(Set(model.warnings.visible.map(\.id)) == [warningA.id, warningB.id])
        model.stopScan()
    }

    // MARK: - Stop / resume lifecycle

    @Test func testStopScanFlagsStoppedWhenPartialResultsShown() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/lifecycle/partial")
        let model = environment.makeModel()

        // Drive the scan through the coordinator directly: at launch the cache
        // index isn't ready, so model.startScan would take the refresh branch
        // (which suppresses partials). The plain scan path is what streams a
        // live partial tree, and this test is about that path.
        model.coordinator.startScan(target, options: ScanOptions())
        // A partial tree puts results on screen without finishing the scan.
        let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: 5)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        environment.scanService.yield(.partial(store), scanIndex: 0)
        try await waitUntilAsync("partial tree displayed") {
            model.coordinator.snapshot != nil
        }

        model.stopScan()
        #expect(model.scanWasStopped)

        // Resuming starts a fresh scan (the engine has no checkpoint) and
        // clears the stopped flag.
        let scansBefore = environment.scanService.scanCount
        model.resumeScan()
        #expect(!model.scanWasStopped)
        #expect(environment.scanService.scanCount > scansBefore)
        model.stopScan()
    }

    @Test func testStopScanDoesNotFlagStoppedWithoutPartialResults() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/lifecycle/empty")
        let model = environment.makeModel()

        model.startScan(target)
        // No partial ever arrives, so there is nothing on screen to resume.
        #expect(model.coordinator.snapshot == nil)
        model.stopScan()
        #expect(!model.scanWasStopped)
    }

    // MARK: - Free/hidden space gating

    @Test func testFolderTargetHasNoFreeOrHiddenSpace() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/space/folder")  // .folder kind
        let model = environment.makeModel()

        model.startScan(target)
        let file = makeTestFileNode(id: target.id + "/file.txt", name: "file.txt", size: 12)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        environment.scanService.yield(
            .finished(makeTestSnapshot(target: target, root: root, store: store)),
            scanIndex: 0
        )
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("scan finished displaying") {
            model.coordinator.snapshot?.isComplete == true
        }

        // FreeSpaceModel.update() only fills these for volume/cloud targets.
        #expect(model.freeSpace.freeSpaceBytes == nil)
        #expect(model.freeSpace.hiddenSpaceBytes == nil)
    }

    // MARK: - Fixtures

    /// A root with three named files whose sizes the caller sets, so scans of
    /// the same target can vary per-file sizes for the diff.
    private func makeThreeFileSnapshot(target: ScanTarget, sizes: [Int64]) -> ScanSnapshot {
        let file1 = makeTestFileNode(id: target.id + "/file1.txt", name: "file1.txt", size: sizes[0])
        let file2 = makeTestFileNode(id: target.id + "/file2.txt", name: "file2.txt", size: sizes[1])
        let file3 = makeTestFileNode(id: target.id + "/file3.txt", name: "file3.txt", size: sizes[2])
        let root = makeTestDirectoryNode(
            id: target.id, name: target.displayName, children: [file1, file2, file3]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file1, file2, file3]])
        return makeTestSnapshot(target: target, root: root, store: store)
    }

    private struct TestEnvironment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let scanService: ControlledScanService
        let sidebarFolderStore: SidebarFolderStore
        let defaults: UserDefaults
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskOutlineResetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledScanService()
            defaultsSuiteName = "NeodiskOutlineResetTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            sidebarFolderStore = SidebarFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel() -> NeodiskViewModel {
            NeodiskViewModel(
                coordinator: ScanCoordinator(
                    scanService: scanService,
                    progressThrottleDuration: .milliseconds(40)
                ),
                snapshotCache: cache,
                sidebarFolderStore: sidebarFolderStore
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }
}
