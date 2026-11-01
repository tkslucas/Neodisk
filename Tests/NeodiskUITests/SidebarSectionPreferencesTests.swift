import Foundation
import Testing
import NeodiskKit
import NeodiskAppModel
@testable import NeodiskUI

/// Sidebar sections persist, and Cleanup's checkbox is the Settings switch for moving to the Trash.
@MainActor
@Suite(.serialized) struct SidebarSectionPreferencesTests {
    private func makeModel() throws -> (NeodiskViewModel, AppPreferences, UserDefaults, String) {
        let suite = "NeodiskSidebarSectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: suite, directoryHint: .isDirectory)
        let model = NeodiskViewModel(
            snapshotCache: ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )
        let preferences = AppPreferences(defaults: defaults)
        model.preferences = preferences
        return (model, preferences, defaults, suite)
    }

    @Test func hiddenAndCollapsedSectionsPersist() throws {
        let (model, _, defaults, suite) = try makeModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.setSidebarSection(.cloudFiles, shown: false)
        model.setSidebarSection(.volumes, expanded: false)
        #expect(!model.isSidebarSectionShown(.cloudFiles))
        let reloaded = AppPreferences(defaults: defaults).sidebarSections
        #expect(!reloaded.isShown(.cloudFiles, cleanupEnabled: true))
        #expect(!reloaded.isExpanded(.volumes))
    }

    @Test func uncheckingCleanupTurnsMovingToTheTrashOff() async throws {
        let (model, preferences, defaults, suite) = try makeModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.setSidebarSection(.cleanup, shown: false)
        #expect(!preferences.allowsMovingToTrash)
        #expect(!model.cleanup.isEnabled)
        // Re-enabled in Settings, the section comes back (the preference sink delivers on the main queue).
        preferences.allowsMovingToTrash = true
        for _ in 0..<50 where !model.isSidebarSectionShown(.cleanup) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isSidebarSectionShown(.cleanup))
    }

    @Test func revealingCleanupOpensTheSidebarAndExpandsIt() throws {
        let (model, _, defaults, suite) = try makeModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.setSidebarSection(.cleanup, expanded: false)
        model.sidebarVisibility = .detailOnly
        model.revealCleanup()
        #expect(model.sidebarVisibility == .all)
        #expect(model.sidebarSections.isExpanded(.cleanup))
        #expect(model.cleanupRevealCount == 1)
    }
}
