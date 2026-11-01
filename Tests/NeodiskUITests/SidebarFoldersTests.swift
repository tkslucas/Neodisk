import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@MainActor
struct SidebarFoldersTests {
    private let common = [makeTestTarget("/sidebar-test/home"), makeTestTarget("/sidebar-test/home/Desktop")]
    private let added = makeTestTarget("/sidebar-test/projects")

    private func withModel(_ body: (NeodiskViewModel, SidebarFolderStore) throws -> Void) throws {
        let suite = "NeodiskSidebarFoldersTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        let store = SidebarFolderStore(defaults: defaults, commonFolders: common)
        try body(NeodiskViewModel(snapshotCache: makeIsolatedCache(), sidebarFolderStore: store), store)
    }

    /// A drag of the app's own items that slips onto the window must not become a new location.
    @Test func droppedFoldersFromTheAppItselfAreIgnored() throws {
        try withModel { model, _ in
            let folder = FileManager.default.temporaryDirectory
            model.cleanup.isDragInProgress = true
            #expect(!model.addDroppedFolders([folder]))
            #expect(!model.sidebarFolders.contains { $0.id == ScanTarget(url: folder).id })
            #expect(model.coordinator.selectedTarget == nil)
        }
    }

    @Test func clearAddedFoldersKeepsTheCommonOnes() throws {
        try withModel { model, store in
            #expect(model.addedSidebarFolders.isEmpty)
            store.add(added)
            model.sidebarFolders.append(added)
            #expect(model.addedSidebarFolders.map(\.id) == [added.id])

            model.removeAddedSidebarFolders()
            #expect(model.sidebarFolders.map(\.id) == common.map(\.id))
            #expect(store.load().map(\.id) == common.map(\.id))
        }
    }

    @Test func removedCommonFoldersComeBackInPlaceAndSurviveRelaunch() throws {
        try withModel { model, store in
            store.add(added)
            model.sidebarFolders.append(added)
            model.removeSidebarFolders(ids: Set(common.map(\.id)))
            #expect(model.isMissingCommonSidebarFolders)

            model.restoreCommonSidebarFolders()
            let expected = common.map(\.id) + [added.id]
            #expect(model.sidebarFolders.map(\.id) == expected)
            #expect(!model.isMissingCommonSidebarFolders)
            #expect(store.load().map(\.id) == expected)
        }
    }
}
