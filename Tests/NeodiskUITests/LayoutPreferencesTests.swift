import Foundation
import Testing
import NeodiskKit
import NeodiskAppModel
@testable import NeodiskUI

/// The statistics tabs' and the bottom table's columns' layouts persist, and a hidden tab never stays the lens.
@MainActor
@Suite(.serialized) struct LayoutPreferencesTests {
    private func makeModel() throws -> (NeodiskViewModel, AppPreferences, UserDefaults, String) {
        let suite = "NeodiskLayoutTests-\(UUID().uuidString)"
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

    @Test func hidingTheActiveTabMovesToTheFirstShownOne() throws {
        let (model, preferences, defaults, suite) = try makeModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.analysisTab = .age
        var layout = model.analysisTabs
        layout.move(.duplicates, onto: .largest)
        layout.setHidden(.age, true)
        model.setAnalysisTabs(layout)
        #expect(model.analysisTab == .duplicates)
        #expect(preferences.analysisTabsRaw == "duplicates,largest,kinds,-age,changes")
        #expect(AppPreferences(defaults: defaults).analysisTabs == layout)
    }

    @Test func outlineColumnsPersistWithNamePinned() throws {
        let (model, preferences, defaults, suite) = try makeModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        var layout = model.outlineColumns
        layout.setVisibleOrder([.name, .modified, .size, .percent, .files])
        layout.setHidden(.percent, true)
        layout.setHidden(.name, true)
        model.setOutlineColumns(layout)
        #expect(preferences.outlineColumnsRaw == "name,modified,size,-percent,files")
        preferences.restoreDefaults()
        #expect(AppPreferences(defaults: defaults).outlineColumns.isStandard)
    }
}
