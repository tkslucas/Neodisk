import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The Folders section's persistence: first-launch seeding with the common
/// folders, the key's presence acting as the seed flag (removing everything
/// sticks), and the one-time fold-in of pre-2.11 pinned folders.
struct SidebarFolderStoreTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SidebarFolderStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test func testFirstLoadSeedsTheCommonFolders() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { removeTestDefaultsSuite(defaults, named: suiteName) }
        let store = SidebarFolderStore(defaults: defaults)

        let seeded = store.load()

        let expected = SystemIntegration.defaultFolderTargets()
        #expect(!seeded.isEmpty)
        #expect(seeded.map(\.id) == expected.map(\.id))
        // The seed persisted: a second load returns it without reseeding.
        #expect(SidebarFolderStore(defaults: defaults).load().map(\.id) == expected.map(\.id))
    }

    @Test func testRemovingEverythingStaysEmptyAcrossLaunches() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { removeTestDefaultsSuite(defaults, named: suiteName) }
        let store = SidebarFolderStore(defaults: defaults)

        for target in store.load() {
            store.remove(target)
        }

        // An empty list is a user decision, not an unseeded state.
        #expect(SidebarFolderStore(defaults: defaults).load().isEmpty)
    }

    @Test func testLegacyPinnedFoldersFoldIntoTheSeedOnce() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { removeTestDefaultsSuite(defaults, named: suiteName) }
        defaults.set(["/legacy/projects"], forKey: "pinnedFolderPaths")
        let store = SidebarFolderStore(defaults: defaults)

        let loaded = store.load()

        #expect(loaded.map(\.id).contains("/legacy/projects"))
        // Seeded defaults come first; the legacy folder is appended.
        #expect(loaded.last?.id == "/legacy/projects")

        // Removing it afterwards sticks — the legacy key is not re-read.
        store.remove(ScanTarget(url: URL(filePath: "/legacy/projects", directoryHint: .isDirectory)))
        #expect(!SidebarFolderStore(defaults: defaults).load().map(\.id).contains("/legacy/projects"))
    }

    @Test func testAddAndRemovePersist() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { removeTestDefaultsSuite(defaults, named: suiteName) }
        let store = SidebarFolderStore(defaults: defaults)
        _ = store.load()

        let added = ScanTarget(url: URL(filePath: "/added/folder", directoryHint: .isDirectory))
        store.add(added)
        store.add(added)  // duplicates are ignored

        let ids = SidebarFolderStore(defaults: defaults).load().map(\.id)
        #expect(ids.filter { $0 == added.id }.count == 1)

        store.remove(added)
        #expect(!SidebarFolderStore(defaults: defaults).load().map(\.id).contains(added.id))
    }
}
