import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The Changes tab's list model: gated on the same previous-snapshot
/// availability as the diff toggle, computed from the cached predecessor,
/// and invalidated when the predecessor rotates.
@MainActor
@Suite(.serialized) struct ChangesModelTests {
    @Test func testLoadsChangeListAgainstThePreviousSnapshot() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/changes-vm/two-scans")
        environment.sidebarFolderStore.add(target)
        // Two generations on disk: v1 has one file, v2 grew it and added one.
        try await environment.cache.save(makeSnapshot(
            target: target, files: [("report.pdf", 100)]
        ))
        try await environment.cache.save(makeSnapshot(
            target: target, files: [("report.pdf", 160), ("fresh.bin", 500)]
        ))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the snapshot with a previous") {
            model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }
        #expect(model.changes.canCompare)

        model.changes.loadIfNeeded()
        try await waitUntilAsync("change list computed") {
            model.changes.list != nil
        }

        let list = try #require(model.changes.list)
        #expect(list.totalEntryCount == 2)
        let added = list.entries.first { $0.path == target.id + "/fresh.bin" }
        #expect(added?.kind == .added)
        #expect(added?.delta == 500)
        let grown = list.entries.first { $0.path == target.id + "/report.pdf" }
        #expect(grown?.kind == .grown)
        #expect(grown?.delta == 60)
        #expect(model.changes.comparisonDate != nil)
        #expect(!model.changes.isLoading)
    }

    @Test func testStaysEmptyWithoutAPreviousSnapshot() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/changes-vm/first-scan")
        environment.sidebarFolderStore.add(target)
        try await environment.cache.save(makeSnapshot(
            target: target, files: [("only.bin", 100)]
        ))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the snapshot") {
            model.session.cachedScanInfo[target.id] != nil
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }

        // One generation only: same gate as the diff toggle — no comparison.
        #expect(!model.changes.canCompare)
        model.changes.loadIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.changes.list == nil)
        #expect(!model.changes.isLoading)
    }

    @Test func testSnapshotChangeClearsTheList() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/changes-vm/clears")
        environment.sidebarFolderStore.add(target)
        try await environment.cache.save(makeSnapshot(target: target, files: [("a.bin", 100)]))
        try await environment.cache.save(makeSnapshot(target: target, files: [("a.bin", 300)]))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the snapshot with a previous") {
            model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }
        model.changes.loadIfNeeded()
        try await waitUntilAsync("change list computed") {
            model.changes.list != nil
        }

        model.changes.snapshotDidChange()

        #expect(model.changes.list == nil)
        #expect(model.changes.comparisonDate == nil)
    }

    @Test func testRotationInvalidatesTheLoadedList() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/changes-vm/rotation")
        environment.sidebarFolderStore.add(target)
        try await environment.cache.save(makeSnapshot(target: target, files: [("a.bin", 100)]))
        try await environment.cache.save(makeSnapshot(target: target, files: [("a.bin", 300)]))

        let model = environment.makeModel(policy: .snapshotOnly)
        try await waitUntilAsync("prune indexes the snapshot with a previous") {
            model.session.cachedScanInfo[target.id]?.hasPreviousSnapshot == true
        }
        model.startScan(target)
        try await waitUntilAsync("snapshot displayed without scanning") {
            model.coordinator.phase == .displaying
        }
        model.changes.loadIfNeeded()
        try await waitUntilAsync("change list computed") {
            model.changes.list != nil
        }
        let tokenBefore = model.changes.reloadToken

        model.changes.snapshotWasRotated(for: target)

        // The stale list stays on screen (no flash) but the pane's task key
        // changes, and the next loadIfNeeded recomputes.
        #expect(model.changes.reloadToken == tokenBefore + 1)
        model.changes.loadIfNeeded()
        try await waitUntilAsync("change list recomputed") {
            !model.changes.isLoading
        }
        #expect(model.changes.list != nil)
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
                .appending(path: "NeodiskChangesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            defaultsSuiteName = "NeodiskChangesTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            sidebarFolderStore = SidebarFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel(policy: AutoRescanPolicy) -> NeodiskViewModel {
            let model = NeodiskViewModel(
                snapshotCache: cache,
                sidebarFolderStore: sidebarFolderStore
            )
            let preferences = AppPreferences(defaults: defaults)
            preferences.autoRescanPolicy = policy
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
