import AppKit
import SwiftUI
import Testing
import NeodiskAppModel
@testable import NeodiskUI

/// Must follow the model's selection without echoing it back as a click, and keep drill-in rows unselected.
@MainActor
struct StatsListTableTests {
    private func makeTable(_ coordinator: StatsListCoordinator) -> OutlineNSTableView {
        let table = OutlineNSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("stats")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.tableView = table
        return table
    }

    private func update(
        _ ids: [String], click: StatsListClick, selectedID: String? = nil
    ) -> StatsListCoordinator.Update {
        StatsListCoordinator.Update(
            ids: ids, cell: { _ in AnyView(EmptyView()) }, click: click,
            selection: NodeSelection(selectedID.map { [$0] } ?? []), keepsLeaderInView: false
        )
    }

    @Test func followsTheModelSelectionWithoutReportingIt() {
        let coordinator = StatsListCoordinator(model: NeodiskViewModel(snapshotCache: makeIsolatedCache()))
        let table = makeTable(coordinator)
        var reported: [String] = []
        let click = StatsListClick.selectsNode { reported.append($0) }

        coordinator.apply(update(["a", "b", "c"], click: click, selectedID: "b"))
        #expect(table.selectedRow == 1)

        // Selected somewhere this list doesn't show: no row stays selected.
        coordinator.apply(update(["a", "b", "c"], click: click, selectedID: "elsewhere"))
        #expect(table.selectedRow == -1)
        #expect(reported.isEmpty)
    }

    @Test func clickingARowSelectsItsNode() {
        let coordinator = StatsListCoordinator(model: NeodiskViewModel(snapshotCache: makeIsolatedCache()))
        let table = makeTable(coordinator)
        var reported: [String] = []
        coordinator.apply(update(["a", "b", "c"], click: .selectsNode { reported.append($0) }))

        table.selectRowIndexes([2], byExtendingSelection: false)

        #expect(reported == ["c"])
    }

    @Test func newRowsKeepTheSelectionOnItsNode() {
        let coordinator = StatsListCoordinator(model: NeodiskViewModel(snapshotCache: makeIsolatedCache()))
        let table = makeTable(coordinator)
        let click = StatsListClick.selectsNode { _ in }
        coordinator.apply(update(["a", "b", "c"], click: click, selectedID: "c"))

        coordinator.apply(update(["c", "a"], click: click, selectedID: "c"))

        #expect(table.numberOfRows == 2)
        #expect(table.selectedRow == 0)
    }

    @Test func drillInRowsHoldNoSelection() {
        let coordinator = StatsListCoordinator(model: NeodiskViewModel(snapshotCache: makeIsolatedCache()))
        let table = makeTable(coordinator)
        coordinator.apply(update(["kind.mov", "kind.jpg"], click: .opens { _ in }, selectedID: "kind.mov"))

        #expect(table.selectedRow == -1)
        #expect(coordinator.tableView(table, shouldSelectRow: 0) == false)
    }

    /// Below the rows (no clicked row), the menu offers the statistics tabs, so hidden ones can come back.
    @Test func spaceBelowTheRowsListsTheTabs() throws {
        let coordinator = StatsListCoordinator(model: NeodiskViewModel(snapshotCache: makeIsolatedCache()))
        let table = makeTable(coordinator)
        coordinator.apply(update(["kind.mov"], click: .opens { _ in }, selectedID: nil))

        let menu = try #require(table.menu)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title).prefix(AnalysisTab.allCases.count) == AnalysisTab.allCases.map(\.localizedTitle)[...])
        #expect(menu.items.last?.title == "Reset Tabs")
    }

    /// A text size change keeps the same rows: their heights must follow it, not stay at the old size.
    @Test func rowsResizeWhenTheTextScaleChanges() {
        let coordinator = StatsListCoordinator(model: NeodiskViewModel(snapshotCache: makeIsolatedCache()))
        let table = makeTable(coordinator)
        var large = update(["a", "b", "c"], click: .selectsNode { _ in })
        large.textScale = 2
        coordinator.apply(large)
        #expect(table.rect(ofRow: 2).height == StatsListMetrics.rowHeight(scale: 2))

        coordinator.apply(update(["a", "b", "c"], click: .selectsNode { _ in }))

        #expect(table.rect(ofRow: 0).height == 37)
        #expect(table.rect(ofRow: 2).height == 37)
    }

    /// 37pt at 100% is what the SwiftUI List gave these two-line rows;
    /// larger text grows the row by its lines, not by a multiple.
    @Test func rowsKeepTheListHeightAndGrowWithTheText() {
        #expect(StatsListMetrics.rowHeight(scale: 1) == 37)
        let doubled = StatsListMetrics.rowHeight(scale: 2)
        #expect(doubled > 37)
        #expect(doubled < 2 * 37)
    }
}
