import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The context-menu subtree actions on the view model: "Expand Contents" /
/// "Show Package Contents" splice a fresh scan of an auto-summarized folder
/// or an opaque package into the displayed tree and persist the spliced
/// snapshot back to the cache.
@MainActor
@Suite(.serialized) struct SubtreeRefreshTests {
    @Test func testExpandSkipsPlainDirectoriesWithoutScanning() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makeSubtreeFixture(rootPath: "/subtree/skips")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        // Neither a plain directory nor a file is auto-summarized or a
        // package, so no context menu offers expansion and the model never
        // starts a scan.
        #expect(model.contentsExpansion(for: fixture.directory) == nil)
        #expect(model.contentsExpansion(for: fixture.file) == nil)
        model.expandNodeContents(fixture.directory)
        model.expandNodeContents(fixture.file)

        #expect(environment.scanService.scanCount == 0)
        #expect(model.coordinator.expandingNodeID == nil)
    }

    @Test func testShowPackageContentsSplicesChildrenInPlace() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makePackageFixture(rootPath: "/subtree/package")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        // An opaque package offers Finder's menu wording.
        #expect(model.contentsExpansion(for: fixture.package) == .package)
        #expect(model.contentsExpansion(for: fixture.package)?.menuTitleKey == "Show Package Contents")

        model.expandNodeContents(fixture.package)
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 1
        }
        let request = try #require(environment.scanService.requests.first)
        #expect(request.target == ScanTarget(url: fixture.package.url))
        // Only the package being shown opens up; bundles nested inside stay
        // opaque, and interior folders may still auto-summarize.
        #expect(request.options.treatRootPackageAsDirectory == true)
        #expect(request.options.treatPackagesAsDirectories == false)
        #expect(request.options.autoSummarizeDirectories == true)

        let refreshed = makeExpandedPackageSnapshot(packageID: fixture.package.id)
        environment.scanService.yield(.finished(refreshed), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)

        try await waitUntilAsync("package contents spliced") {
            model.store?.containsChildren(id: fixture.package.id) == true
        }
        let spliced = try #require(model.store?.node(id: fixture.package.id))
        // The node keeps its package identity — icon, kind, and Quick Look
        // still see a bundle — but now behaves like a folder with children.
        #expect(spliced.isPackage)
        #expect(model.store?.children(of: spliced.id).map(\.name) == ["Contents"])
        // The menu item disappears once the contents are in the store.
        #expect(model.contentsExpansion(for: spliced) == nil)
        // The reveal lands a main-actor hop after the splice, so wait for it.
        try await waitUntilAsync("expansion result revealed") {
            model.expandedNodeIDs.contains(fixture.package.id)
        }
        #expect(model.actionErrorMessage == nil)
    }

    @Test func testExpandSummarizedNodeSplicesAndRevealsContents() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makeSummarizedFixture(rootPath: "/subtree/summarized")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        #expect(model.canRefreshSubtree)
        model.expandNodeContents(fixture.summarized)

        // The expansion starts in a task; wait for the scan to register.
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 1
        }
        #expect(model.coordinator.expandingNodeID == fixture.summarized.id)
        #expect(!model.canRefreshSubtree)
        #expect(environment.scanService.scanCount == 1)
        let request = try #require(environment.scanService.requests.first)
        #expect(request.target == ScanTarget(url: fixture.summarized.url))
        // Re-summarizing the folder the user asked to expand would make the
        // action a no-op.
        #expect(request.options.autoSummarizeDirectories == false)

        // A second request while the first is in flight is ignored.
        model.expandNodeContents(fixture.summarized)
        #expect(environment.scanService.scanCount == 1)

        let refreshed = makeRefreshedSubtreeSnapshot(directoryID: fixture.summarized.id)
        environment.scanService.yield(.finished(refreshed), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)

        try await waitUntilAsync("summarized node expanded") {
            model.store?.node(id: fixture.summarized.id)?.isAutoSummarized == false
        }
        #expect(model.store?.children(of: fixture.summarized.id).map(\.name) == ["new1.bin", "new2.bin"])
        // The replacement root is revealed and opened in the outline. The
        // reveal lands a main-actor hop after the splice, so wait for it.
        try await waitUntilAsync("expansion result revealed") {
            model.expandedNodeIDs.contains(fixture.summarized.id)
        }
        #expect(model.expandedNodeIDs.contains(fixture.snapshot.root.id))
        #expect(model.coordinator.expandingNodeID == nil)
        #expect(model.canRefreshSubtree)
        #expect(model.store?.root.id == fixture.snapshot.root.id)
        #expect(model.actionErrorMessage == nil)
    }

    @Test func testFailedSubtreeRefreshSetsActionErrorMessage() async throws {
        struct StubScanError: Error {}
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let fixture = makeSummarizedFixture(rootPath: "/subtree/failing")
        model.coordinator.replaceCurrentSnapshot(fixture.snapshot)

        model.expandNodeContents(fixture.summarized)
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 1
        }
        environment.scanService.finish(scanIndex: 0, throwing: StubScanError())

        try await waitUntilAsync("failure surfaced") {
            model.actionErrorMessage != nil
        }
        #expect(model.actionErrorMessage?.contains(fixture.summarized.name) == true)
        #expect(model.coordinator.expandingNodeID == nil)
        // The displayed tree is untouched.
        #expect(model.store?.node(id: fixture.summarized.id)?.isAutoSummarized == true)
    }

    @Test func testSplicedSnapshotIsPersistedToCache() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/subtree/persisted")
        environment.sidebarFolderStore.add(target)
        let model = environment.makeModel()

        // Full scan first: it persists and records the honest full-scan
        // date/duration in the cache index.
        model.startScan(target)
        let fixture = makeSummarizedFixture(rootPath: target.id, target: target)
        environment.scanService.yield(.finished(fixture.snapshot), scanIndex: 0)
        environment.scanService.finish(scanIndex: 0)
        try await waitUntilAsync("full scan persisted") {
            await environment.cache.loadSnapshot(for: target) != nil
        }
        let fullScanInfo = try #require(model.session.cachedScanInfo[target.id])

        // Expand one folder; the spliced snapshot must reach the cache.
        let summarized = try #require(model.store?.node(id: fixture.summarized.id))
        model.expandNodeContents(summarized)
        try await waitUntilAsync("expansion scan started") {
            environment.scanService.scanCount == 2
        }
        let refreshed = makeRefreshedSubtreeSnapshot(directoryID: fixture.summarized.id)
        environment.scanService.yield(.finished(refreshed), scanIndex: 1)
        environment.scanService.finish(scanIndex: 1)

        try await waitUntilAsync("spliced snapshot persisted") {
            let cached = await environment.cache.loadSnapshot(for: target)
            return cached?.treeStore.node(id: fixture.summarized.id + "/new1.bin") != nil
        }

        // The cache index keeps the full scan's date and duration (a subtree
        // refresh predicts nothing about a full rescan); only the node count
        // reflects the splice, and the pre-splice snapshot rotated into the
        // previous slot.
        let splicedInfo = try #require(model.session.cachedScanInfo[target.id])
        #expect(splicedInfo.lastScanDate == fullScanInfo.lastScanDate)
        #expect(splicedInfo.lastScanDuration == fullScanInfo.lastScanDuration)
        #expect(splicedInfo.nodeCount == 4)
        #expect(splicedInfo.hasPreviousSnapshot)
        let previous = await environment.cache.loadPreviousSnapshot(for: target)
        #expect(previous?.treeStore.node(id: fixture.summarized.id)?.isAutoSummarized == true)
    }

    // MARK: - Fixtures

    private struct TestEnvironment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let scanService: ControlledScanService
        let sidebarFolderStore: SidebarFolderStore
        private let defaults: UserDefaults
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskSubtreeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledScanService()
            defaultsSuiteName = "NeodiskSubtreeTests-\(UUID().uuidString)"
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

    private struct SubtreeFixture {
        let snapshot: ScanSnapshot
        let directory: FileNodeRecord
        let file: FileNodeRecord
    }

    /// Root with one plain directory (containing old.bin) and one loose file.
    private func makeSubtreeFixture(rootPath: String, target: ScanTarget? = nil) -> SubtreeFixture {
        let oldFile = makeTestFileNode(id: rootPath + "/stuff/old.bin", name: "old.bin", size: 100)
        let directory = makeTestDirectoryNode(id: rootPath + "/stuff", name: "stuff", children: [oldFile])
        let looseFile = makeTestFileNode(id: rootPath + "/readme.txt", name: "readme.txt", size: 5)
        let root = makeTestDirectoryNode(id: rootPath, name: "root", children: [directory, looseFile])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [directory, looseFile], directory.id: [oldFile]]
        )
        return SubtreeFixture(
            snapshot: makeTestSnapshot(target: target, root: root, store: store),
            directory: directory,
            file: looseFile
        )
    }

    private struct SummarizedFixture {
        let snapshot: ScanSnapshot
        let summarized: FileNodeRecord
    }

    private func makeSummarizedFixture(rootPath: String, target: ScanTarget? = nil) -> SummarizedFixture {
        let summarized = FileNodeRecord(
            id: rootPath + "/stuff",
            url: URL(filePath: rootPath + "/stuff", directoryHint: .isDirectory),
            name: "stuff",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 100,
            logicalSize: 100,
            descendantFileCount: 12,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let root = makeTestDirectoryNode(id: rootPath, name: "root", children: [summarized])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [summarized]])
        return SummarizedFixture(
            snapshot: makeTestSnapshot(target: target, root: root, store: store),
            summarized: summarized
        )
    }

    /// A fresh scan of the fixture directory: old.bin gone, two new files.
    private func makeRefreshedSubtreeSnapshot(directoryID: String) -> ScanSnapshot {
        let new1 = makeTestFileNode(id: directoryID + "/new1.bin", name: "new1.bin", size: 70)
        let new2 = makeTestFileNode(id: directoryID + "/new2.bin", name: "new2.bin", size: 30)
        let root = makeTestDirectoryNode(id: directoryID, name: "stuff", children: [new1, new2])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [new1, new2]])
        return makeTestSnapshot(root: root, store: store)
    }

    private struct PackageFixture {
        let snapshot: ScanSnapshot
        let package: FileNodeRecord
    }

    /// Root with one opaque package leaf, the way the scanner records
    /// bundles: `isPackage`, aggregate size, no children in the store.
    private func makePackageFixture(rootPath: String, target: ScanTarget? = nil) -> PackageFixture {
        let package = FileNodeRecord(
            id: rootPath + "/App.app",
            url: URL(filePath: rootPath + "/App.app", directoryHint: .isDirectory),
            name: "App.app",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 100,
            logicalSize: 100,
            descendantFileCount: 7,
            lastModified: nil,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let root = makeTestDirectoryNode(id: rootPath, name: "root", children: [package])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [package]])
        return PackageFixture(
            snapshot: makeTestSnapshot(target: target, root: root, store: store),
            package: package
        )
    }

    /// A fresh scan of the fixture package with the root opened up: the
    /// replacement root keeps `isPackage` and now has children.
    private func makeExpandedPackageSnapshot(packageID: String) -> ScanSnapshot {
        let contents = makeTestFileNode(id: packageID + "/Contents", name: "Contents", size: 100)
        let root = makeTestDirectoryNode(
            id: packageID, name: "App.app", children: [contents], isPackage: true
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: [contents]])
        return makeTestSnapshot(root: root, store: store)
    }
}
