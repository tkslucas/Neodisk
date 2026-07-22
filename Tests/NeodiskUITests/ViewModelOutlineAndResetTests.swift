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

        let beforeDiff = model.outlineRowsSnapshot()

        // Opening the Changes tab arms the diff; siblings then order by
        // |sizeDelta| descending: file2(−20), file3(+5), file1(+1).
        model.analysisTab = .changes
        try await waitUntilAsync("baseline loaded") {
            model.diff.baseline != nil
        }
        let withDiff = model.outlineRowsSnapshot()
        #expect(withDiff.structuralVersion != beforeDiff.structuralVersion)
        let diffOrder = model.visibleOutlineRows()
            .filter { $0.id != target.id }
            .map(\.id)
        #expect(diffOrder == [
            target.id + "/file2.txt",
            target.id + "/file3.txt",
            target.id + "/file1.txt",
        ])

        // The diff ordering outranks a bottom-table header sort, so the
        // changes read top-down in both outline layouts.
        let sortedDiffOrder = model
            .visibleOutlineRows(sortedBy: OutlineSort(field: .name, ascending: true))
            .filter { $0.id != target.id }
            .map(\.id)
        #expect(sortedDiffOrder == diffOrder)

        // Leaving the tab drops the baseline; ordering reverts to the store's
        // own size-descending order: file3(15), file1(11), file2(10).
        model.analysisTab = .largest
        #expect(model.diff.baseline == nil)
        #expect(model.outlineRowsSnapshot().structuralVersion != withDiff.structuralVersion)
        let storeOrder = model.visibleOutlineRows()
            .filter { $0.id != target.id }
            .map(\.id)
        #expect(storeOrder == [
            target.id + "/file3.txt",
            target.id + "/file1.txt",
            target.id + "/file2.txt",
        ])
    }

    @Test func testVisibleOutlineRowsComputeFractionOfParent() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/fractions")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))
        model.toggleExpansion(target.id + "/dirA")

        // Root totals 190 (dirA 150 + dirB 30 + file4 10); each row's
        // fraction is its share of its own parent, not of the root.
        let fractions = Dictionary(
            uniqueKeysWithValues: model.visibleOutlineRows().map { ($0.id, $0.fractionOfParent) }
        )
        #expect(fractions[target.id] == 1)
        #expect(fractions[target.id + "/dirA"] == 150.0 / 190.0)
        #expect(fractions[target.id + "/dirB"] == 30.0 / 190.0)
        #expect(fractions[target.id + "/file4.bin"] == 10.0 / 190.0)
        #expect(fractions[target.id + "/dirA/file1.bin"] == 100.0 / 150.0)
        #expect(fractions[target.id + "/dirA/file2.bin"] == 50.0 / 150.0)
    }

    @Test func testHeaderSortReordersSiblingsPerLevel() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/sorted")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))

        func topLevel(_ sort: OutlineSort) -> [String] {
            model.visibleOutlineRows(sortedBy: sort)
                .filter { $0.depth == 1 }
                .map(\.node.name)
        }

        #expect(topLevel(OutlineSort(field: .name, ascending: true))
            == ["dirA", "dirB", "file4.bin"])
        #expect(topLevel(OutlineSort(field: .name, ascending: false))
            == ["file4.bin", "dirB", "dirA"])
        // Size ascending inverts the store's default descending order.
        #expect(topLevel(OutlineSort(field: .size, ascending: true))
            == ["file4.bin", "dirB", "dirA"])
        // File counts: dirA 2, dirB 1, file4 1 — the tie between dirB and
        // file4 falls back to descending size (30 vs 10) either direction.
        #expect(topLevel(OutlineSort(field: .files, ascending: false))
            == ["dirA", "dirB", "file4.bin"])
        #expect(topLevel(OutlineSort(field: .files, ascending: true))
            == ["dirB", "file4.bin", "dirA"])
    }

    @Test func testModifiedSortTreatsUnknownDatesAsOldest() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/modified")
        let model = environment.makeModel()

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let dateless = makeTestFileNode(id: target.id + "/a.txt", name: "a.txt", size: 99)
        let old = makeTestFileNode(
            id: target.id + "/b.txt", name: "b.txt", size: 1, lastModified: older
        )
        let new = makeTestFileNode(
            id: target.id + "/c.txt", name: "c.txt", size: 1, lastModified: newer
        )
        let root = makeTestDirectoryNode(
            id: target.id, name: target.displayName, children: [dateless, old, new]
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [dateless, old, new]])
        model.coordinator.replaceCurrentSnapshot(makeTestSnapshot(target: target, root: root, store: store))

        func names(ascending: Bool) -> [String] {
            model.visibleOutlineRows(sortedBy: OutlineSort(field: .modified, ascending: ascending))
                .filter { $0.depth == 1 }
                .map(\.node.name)
        }

        #expect(names(ascending: false) == ["c.txt", "b.txt", "a.txt"])
        #expect(names(ascending: true) == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func testSelectionOnlyReusesRowsAndSkipsBothCoordinatorApplies() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/selection-fast-path")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))
        model.toggleExpansion(target.id + "/dirA")

        let leading = model.outlineRowsSnapshot()
        let bottom = model.outlineRowsSnapshot(sortedBy: model.outlineSort)
        let buildCount = model.outlineRowsCache.buildCount
        let expansionRevision = model.outlineExpansionRevision

        let leadingCoordinator = OutlineTreeTable.Coordinator(model: model)
        let bottomCoordinator = BottomOutlineTable.Coordinator(model: model)
        leadingCoordinator.apply(snapshot: leading)
        bottomCoordinator.apply(snapshot: bottom)
        #expect(leadingCoordinator.structuralApplyCount == 1)
        #expect(bottomCoordinator.structuralApplyCount == 1)

        // The selected file is already visible. Revealing its ancestors is
        // therefore a true no-op and must not invalidate structural rows.
        model.select(target.id + "/dirA/file2.bin")
        let leadingAfterSelection = model.outlineRowsSnapshot()
        let bottomAfterSelection = model.outlineRowsSnapshot(sortedBy: model.outlineSort)

        #expect(model.outlineExpansionRevision == expansionRevision)
        #expect(model.outlineRowsCache.buildCount == buildCount)
        #expect(leadingAfterSelection.structuralVersion == leading.structuralVersion)
        #expect(bottomAfterSelection.structuralVersion == bottom.structuralVersion)
        #expect(leadingAfterSelection.rowIndexByID[target.id + "/dirA/file2.bin"] == 3)

        leadingCoordinator.apply(snapshot: leadingAfterSelection)
        bottomCoordinator.apply(snapshot: bottomAfterSelection)
        #expect(leadingCoordinator.structuralApplyCount == 1)
        #expect(bottomCoordinator.structuralApplyCount == 1)
    }

    @Test func testOutlineCacheInvalidatesForEveryStructuralInput() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/cache-inputs")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))

        let initial = model.outlineRowsSnapshot()
        #expect(model.outlineRowsSnapshot().structuralVersion == initial.structuralVersion)

        // One reveal operation may add several ancestors, but advances the
        // revision exactly once and causes one new flatten.
        let revision = model.outlineExpansionRevision
        model.revealInOutline(target.id + "/dirA/file1.bin")
        #expect(model.outlineExpansionRevision == revision + 1)
        let expanded = model.outlineRowsSnapshot()
        #expect(expanded.structuralVersion != initial.structuralVersion)

        model.zoomRootID = target.id + "/dirA"
        let rerooted = model.outlineRowsSnapshot()
        #expect(rerooted.structuralVersion != expanded.structuralVersion)

        let sizeSort = model.outlineRowsSnapshot(
            sortedBy: OutlineSort(field: .size, ascending: false)
        )
        let nameSort = model.outlineRowsSnapshot(
            sortedBy: OutlineSort(field: .name, ascending: true)
        )
        #expect(nameSort.structuralVersion != sizeSort.structuralVersion)
        #expect(model.outlineRowsSnapshot(
            sortedBy: OutlineSort(field: .name, ascending: true)
        ).structuralVersion == nameSort.structuralVersion)

        // A subtree splice and any other store replacement create a new
        // snapshot UUID, even when target, root, and expansion stay equal.
        model.coordinator.replaceCurrentSnapshot(makeMultiLevelSnapshot(target: target))
        let replaced = model.outlineRowsSnapshot()
        #expect(replaced.structuralVersion != rerooted.structuralVersion)
    }

    @Test func testOutlineCacheInvalidatesWhenCloudWeightingChanges() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/cloud-weight")
        let model = environment.makeModel()
        let cloud = FileNodeRecord(
            id: target.id + "/remote.bin",
            url: URL(filePath: target.id + "/remote.bin"),
            name: "remote.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 100,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false,
            isDataless: true
        )
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [cloud])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [cloud]])
        model.coordinator.replaceCurrentSnapshot(
            makeTestSnapshot(target: target, root: root, store: store)
        )

        #expect(model.showsCloudOnlyFiles)
        let included = model.outlineRowsSnapshot()
        model.showCloudOnlyFilesPreferred = false
        #expect(!model.showsCloudOnlyFiles)
        let excluded = model.outlineRowsSnapshot()
        #expect(excluded.structuralVersion != included.structuralVersion)
        #expect(excluded.rows[1].fractionOfParent != included.rows[1].fractionOfParent)
    }

    /// Release-mode call-count probe for the real problem size. Run with:
    /// `NEODISK_OUTLINE_BENCH=1 swift test -c release --filter outline100kSelectionProbe`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEODISK_OUTLINE_BENCH"] == "1"))
    func outline100kSelectionProbe() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/100k")
        let model = environment.makeModel()
        let files = (0..<100_000).map { index in
            makeTestFileNode(
                id: target.id + "/\(index).bin",
                name: "\(index).bin",
                size: Int64(100_000 - index)
            )
        }
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: files)
        let store = FileTreeStore(root: root, childrenByID: [root.id: files])
        model.coordinator.replaceCurrentSnapshot(
            makeTestSnapshot(target: target, root: root, store: store)
        )

        let initial = model.outlineRowsSnapshot()
        let builds = model.outlineRowsCache.buildCount
        for row in stride(from: 1, to: initial.rows.count, by: 997) {
            model.selectedNodeID = initial.rows[row].id
            #expect(model.outlineRowsSnapshot().structuralVersion == initial.structuralVersion)
        }
        #expect(model.outlineRowsCache.buildCount == builds)
    }

    // MARK: - Per-scan state reset

    @Test func visualizationHoverPublishesAtomicallyAndDeduplicatesIdentity() throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let swatch = SIMD3<Float>(0.1, 0.2, 0.3)

        #expect(model.setVisualizationHover(.node(id: "/file", swatchRGB: swatch)))
        #expect(model.hoveredNodeID == "/file")
        #expect(model.hoveredAggregate == nil)
        #expect(!model.setVisualizationHover(.node(id: "/file", swatchRGB: swatch)))

        #expect(model.setVisualizationHover(.aggregate(
            folderID: "/folder", itemCount: 7, totalSize: 42, swatchRGB: swatch
        )))
        #expect(model.hoveredNodeID == "/folder")
        #expect(model.hoveredAggregate == .init(itemCount: 7, totalSize: 42))
        #expect(!model.hoveredCellIsFreeSpace)
        #expect(!model.hoveredCellIsHiddenSpace)

        #expect(model.setVisualizationHover(.freeSpace(swatchRGB: swatch)))
        #expect(model.hoveredNodeID == nil)
        #expect(model.hoveredCellIsFreeSpace)
        #expect(!model.hoveredCellIsHiddenSpace)
    }

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
        model.setVisualizationHover(.node(id: file.id, swatchRGB: .zero))
        model.zoomRootID = targetA.id
        model.expandedAggregateIDs = [targetA.id]
        model.stopScan()
        #expect(model.scanWasStopped)

        // Scanning a DIFFERENT target wipes selection/hover/zoom, empties the
        // expanded sets, and unsets scanWasStopped.
        model.startScan(targetB)
        #expect(model.selectedNodeID == nil)
        #expect(model.hoveredNodeID == nil)
        #expect(model.zoomRootID == nil)
        #expect(model.expandedNodeIDs.isEmpty)
        #expect(model.expandedAggregateIDs.isEmpty)
        #expect(!model.scanWasStopped)
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
        attachLiveScan(model.coordinator, target: target)
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
