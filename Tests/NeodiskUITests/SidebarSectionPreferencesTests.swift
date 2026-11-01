import Foundation
import Testing
import NeodiskAppModel
@testable import NeodiskUI

/// Sidebar sections persist; hiding Cleanup leaves the Settings switch for moving to the Trash alone.
@MainActor
@Suite(.serialized) struct SidebarSectionPreferencesTests {
    @Test func hiddenAndCollapsedSectionsPersist() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.setSidebarSection(.cloudFiles, shown: false)
        model.setSidebarSection(.volumes, expanded: false)
        #expect(!model.isSidebarSectionShown(.cloudFiles))
        let reloaded = AppPreferences(defaults: defaults).sidebarSections
        #expect(!reloaded.isShown(.cloudFiles, cleanupEnabled: true))
        #expect(!reloaded.isExpanded(.volumes))
    }

    @Test func hidingCleanupKeepsMovingToTheTrashOn() throws {
        let (model, preferences, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        let wasAllowed = preferences.allowsMovingToTrash
        model.setSidebarSection(.cleanup, shown: false)
        #expect(!model.isSidebarSectionShown(.cleanup))
        #expect(preferences.allowsMovingToTrash == wasAllowed)
        #expect(model.cleanup.isEnabled == wasAllowed)
        model.setSidebarSection(.cleanup, shown: true)
        #expect(model.isSidebarSectionShown(.cleanup) == wasAllowed)
    }

    @Test func revealingCleanupOpensTheSidebarAndExpandsIt() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.setSidebarSection(.cleanup, expanded: false)
        model.sidebarVisibility = .detailOnly
        model.revealCleanup()
        #expect(model.sidebarVisibility == .all)
        #expect(model.sidebarSections.isExpanded(.cleanup))
        #expect(model.isCleanupRevealPending)
    }
}
