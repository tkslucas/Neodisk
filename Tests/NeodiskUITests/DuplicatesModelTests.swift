import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The Duplicates tab's model loading a persisted result from the `.nddup`
/// cache: a cache hit must enter `.finished` without re-hashing, and it must
/// rebuild the map-wide highlight index so treemap highlighting and
/// click-to-open-group keep working for restored results.
@MainActor
@Suite(.serialized) struct DuplicatesModelTests {
    @Test func testLoadsCachedResultsWithoutHashing() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/dupes-vm/cached")
        environment.sidebarFolderStore.add(target)

        // One snapshot on disk, plus a persisted duplicate result whose group
        // holds node IDs that are not backed by real files — so if the hasher
        // ran it would find nothing, and a non-empty result can only come from
        // the cache.
        try await environment.cache.save(makeSnapshot(
            target: target, files: [("a.bin", 2_000_000), ("b.bin", 2_000_000)]
        ))
        let group = DuplicateGroup(
            id: "hash-2000000",
            fileSize: 2_000_000,
            nodeIDs: [target.id + "/a.bin", target.id + "/b.bin"]
        )
        let results = DuplicateScanResults(
            groups: [group], totalWastedBytes: 2_000_000, candidateCount: 2, unreadableCount: 0
        )
        let computedAt = Date(timeIntervalSinceReferenceDate: 99_999)
        await environment.cache.saveDuplicateResults(
            results,
            computedAt: computedAt,
            forTargetID: target.id,
            minimumFileSize: DuplicatesModel.minimumFileSize
        )

        let model = environment.makeModel()
        try await waitUntilAsync("prune indexes the snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }

        model.duplicates.loadIfNeeded()
        try await waitUntilAsync("cached duplicate result loads into finished") {
            model.duplicates.results != nil
        }

        // The finished result is the cached one, timestamp carried through.
        let loaded = try #require(model.duplicates.results)
        #expect(loaded == results)
        #expect(model.duplicates.computedAt.map { abs($0.timeIntervalSince(computedAt)) < 0.001 } == true)

        // Highlight index rebuilt: every copy lights on the map.
        #expect(model.duplicates.highlightedNodeIDs == Set(group.nodeIDs))

        // Click-to-open-group rebuilt: selecting a copy opens its group.
        model.duplicates.handleSelection(of: group.nodeIDs[0])
        #expect(model.duplicates.openGroup == group)
    }

    @Test func testNoCachedResultLeavesTabIdle() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/dupes-vm/no-cache")
        environment.sidebarFolderStore.add(target)
        try await environment.cache.save(makeSnapshot(target: target, files: [("only.bin", 2_000_000)]))

        let model = environment.makeModel()
        try await waitUntilAsync("prune indexes the snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }

        // No persisted result and no auto-scan: the tab stays idle rather than
        // hashing on its own.
        model.duplicates.loadIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.duplicates.results == nil)
        #expect(!model.duplicates.isScanning)
        #expect(model.duplicates.computedAt == nil)
    }

    @Test func testLiveScanDimsMapImmediatelyAndFinishesWithHighlight() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }

        // Real files on disk, so the model's scan actually hashes them.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NeodiskDupesLive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identical = Data(repeating: 0xAB, count: 2 << 20)
        let copy1 = directory.appending(path: "copy-1.bin")
        let copy2 = directory.appending(path: "copy-2.bin")
        try identical.write(to: copy1)
        try identical.write(to: copy2)

        let target = makeTestTarget(directory.path)
        environment.sidebarFolderStore.add(target)
        let children = [
            makeTestFileNode(id: copy1.path, name: "copy-1.bin", size: Int64(identical.count)),
            makeTestFileNode(id: copy2.path, name: "copy-2.bin", size: Int64(identical.count)),
        ]
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        try await environment.cache.save(makeTestSnapshot(target: target, root: root, store: store))

        let model = environment.makeModel()
        try await waitUntilAsync("prune indexes the snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }

        model.duplicates.startScan()
        // Hashing dims the whole map from the first frame: a non-nil empty
        // highlight, distinct from the idle tab's nil.
        #expect(model.duplicates.isScanning)
        #expect(model.duplicates.highlightedNodeIDs == Set<String>())

        try await waitUntilAsync("scan finishes with the pair") {
            model.duplicates.results != nil
        }
        let results = try #require(model.duplicates.results)
        #expect(results.groups.count == 1)
        // Finishing supersedes the live state; every copy stays lit.
        #expect(model.duplicates.liveGroups.isEmpty)
        #expect(model.duplicates.highlightedNodeIDs == Set([copy1.path, copy2.path]))
    }

    // MARK: - Fixtures

    private struct TestEnvironment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let sidebarFolderStore: SidebarFolderStore
        let defaults: UserDefaults
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskDupesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            defaultsSuiteName = "NeodiskDupesTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            sidebarFolderStore = SidebarFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel() -> NeodiskViewModel {
            let model = NeodiskViewModel(
                snapshotCache: cache,
                sidebarFolderStore: sidebarFolderStore
            )
            let preferences = AppPreferences(defaults: defaults)
            preferences.autoRescanPolicy = .snapshotOnly
            preferences.autoScanDuplicates = false
            model.preferences = preferences
            return model
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }

    private func makeSnapshot(target: ScanTarget, files: [(String, Int64)]) -> ScanSnapshot {
        let children = files.map { name, size in
            makeTestFileNode(id: target.id + "/" + name, name: name, size: size)
        }
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        return makeTestSnapshot(target: target, root: root, store: store)
    }
}
