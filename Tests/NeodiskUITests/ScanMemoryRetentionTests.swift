import Foundation
import Testing
@testable import NeodiskKit
@testable import NeodiskUI

/// A replaced scan's tree must be freed: holding it is the issue-#9 leak class.
extension ScanTimingSuites {
@MainActor
@Suite(.serialized) struct ScanMemoryRetentionTests {
    /// A splice (deleted files, an expanded folder) swaps the tree without a scan:
    /// the Largest list kept its rows' whole tree alive across it (fixed in 2.82.1).
    @Test func replacedTreeIsFreed() async throws {
        let environment = try TestEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel()
        let target = makeTestTarget("/scan-memory/splice")

        model.coordinator.replaceCurrentSnapshot(makeSnapshot(target: target, files: 40))
        weak var firstTree = model.coordinator.snapshot?.treeStore.storage
        #expect(firstTree != nil)
        model.largest.loadIfNeeded()
        try await waitUntil("largest rows loaded") { !model.largest.visibleIDs.isEmpty }

        model.coordinator.replaceCurrentSnapshot(makeSnapshot(target: target, files: 39))
        try await waitUntil("replaced tree freed", timeout: 3) { firstTree == nil }
    }

    private func makeSnapshot(target: ScanTarget, files: Int) -> ScanSnapshot {
        let children = (0..<files).map { index in
            makeTestFileNode(id: target.id + "/f\(index)", name: "f\(index)", size: Int64(index + 1) * 100)
        }
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
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
                .appending(path: "NeodiskMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            scanService = ControlledScanService()
            defaultsSuiteName = "NeodiskMemoryTests-\(UUID().uuidString)"
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
}
}
