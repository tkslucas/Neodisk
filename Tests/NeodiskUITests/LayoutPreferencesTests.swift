import AppKit
import Foundation
import Testing
import NeodiskAppModel
@testable import NeodiskUI

/// The statistics tabs' and the bottom table's columns' layouts persist, and a hidden tab never stays the lens.
@MainActor
@Suite(.serialized) struct LayoutPreferencesTests {
    @Test func hidingTheActiveTabMovesToTheFirstShownOne() throws {
        let (model, preferences, defaults, suite) = try makePreferencesModel()
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
        let (model, preferences, defaults, suite) = try makePreferencesModel()
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

    /// Settings' reset while the table is on screen: rearranging it to match mustn't store the half-done orders
    /// each column move reports.
    @Test func bottomTableFollowsAResetWithoutStoringItsSteps() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        let custom = ItemLayout<OutlineColumn>(stored: "name,modified,files,size,-percent", pinned: .name)
        model.setOutlineColumns(custom)
        let coordinator = BottomOutlineTable.Coordinator(model: model)
        let tableView = NSTableView()
        for id in custom.order {
            let column = NSTableColumn(identifier: .init(id.rawValue))
            column.isHidden = custom.isHidden(id)
            tableView.addTableColumn(column)
        }
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.appliedColumns = custom

        let standard = ItemLayout<OutlineColumn>(pinned: .name)
        model.setOutlineColumns(standard)
        let writes = DefaultsWrites(defaults, key: "outlineColumns")
        coordinator.applyColumns(standard)

        #expect(tableView.tableColumns.map(\.identifier.rawValue) == standard.order.map(\.rawValue))
        #expect(!tableView.tableColumns.contains { $0.isHidden })
        #expect(model.outlineColumns == standard)
        #expect(writes.values.isEmpty)
        writes.stop()
    }

    /// The View menu and the picker go through WorkspaceLayout and persist; its rules are tested on their own.
    @Test func viewsAndFileListPersist() throws {
        let (model, preferences, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.updateLayout { $0.pick(.flat) }
        model.updateLayout {
            $0.setHidden(.flat, true)
            $0.setListShown(false)
        }
        #expect(model.vizView == .cushion)
        #expect(!model.layout.showsList)
        #expect(preferences.vizViewsRaw == "cushion,-flat,sunburst")
        #expect(AppPreferences(defaults: defaults).workspaceLayout == model.layout)
        preferences.restoreDefaults()
        #expect(AppPreferences(defaults: defaults).workspaceLayout == WorkspaceLayout())
    }

    @Test func aHiddenDefaultViewStaysHiddenAtLaunch() throws {
        let (model, preferences, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        preferences.defaultVizView = .sunburst
        model.updateLayout { $0.setHidden(.sunburst, true) }
        #expect(preferences.defaultVizView == .lastViewed)
        let relaunched = AppPreferences(defaults: defaults)
        #expect(relaunched.workspaceLayout.views.isHidden(.sunburst))
        #expect(relaunched.vizViewMode == .treemap)
    }

    @Test func statusBarVisibilityPersists() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        #expect(model.showsStatusBar)
        model.setStatusBarShown(false)
        #expect(!model.showsStatusBar)
        #expect(!AppPreferences(defaults: defaults).showStatusBar)
    }

    @Test func fileListMenuShowsWhereTheListIs() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.updateLayout { $0.placeList(.leading) }
        let menu = NSMenu()
        menu.addFileListLayoutItems(model: model)
        #expect(menu.items.map(\.title) == ["File List at Bottom", "File List on the Left", "Hide File List"])
        #expect(menu.items.map(\.state) == [.off, .on, .off])
    }

    /// The picker's own menu is the checklist (a SwiftUI context menu loses the right-click to the toolbar's).
    @Test func viewPickerMenuChecksShownViewsAndKeepsTheLast() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        model.updateLayout {
            $0.setHidden(.cushion, true)
            $0.setHidden(.flat, true)
        }
        let picker = VizViewPicker(views: model.layout.views, current: model.vizView, isEnabled: true, update: model.updateLayout)
        let coordinator = VizViewPicker.Coordinator()
        coordinator.picker = picker
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.state) == [.off, .off, .on])
        #expect(menu.items.map(\.isEnabled) == [true, true, false])
    }
}

/// The values written to one defaults key while it's watched.
private final class DefaultsWrites: NSObject {
    private let defaults: UserDefaults
    private let key: String
    private(set) var values: [String] = []

    init(_ defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    func stop() {
        defaults.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        values.append(change?[.newKey] as? String ?? "")
    }
}

/// Right-clicking the map where there's no item offers the views checklist the toolbar picker has.
@MainActor
@Suite(.serialized) struct MapViewChecklistTests {
    @Test func checklistHidesAndRestoresViewsAndKeepsTheLastOne() throws {
        let (model, _, defaults, suite) = try makePreferencesModel()
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        func items() -> [NSMenuItem] { NSMenu.viewChecklist(model: model).items }
        #expect(items().map(\.state) == [.on, .on, .on])

        let sunburst = try #require(items().last)
        _ = sunburst.target?.perform(sunburst.action, with: sunburst)
        #expect(model.layout.views.isHidden(.sunburst))
        #expect(items().last?.state == .off)

        // Hide Flat too: Cushion is the last view shown, so it can't be unchecked; hidden ones can come back.
        let flat = items()[1]
        _ = flat.target?.perform(flat.action, with: flat)
        #expect(items().map(\.isEnabled) == [false, true, true])

        let restore = try #require(items().last)
        _ = restore.target?.perform(restore.action, with: restore)
        #expect(!model.layout.views.isHidden(.sunburst))
    }
}
