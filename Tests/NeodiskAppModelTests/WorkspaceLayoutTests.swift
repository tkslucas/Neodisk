import Testing
import TreemapKit
@testable import NeodiskAppModel

struct WorkspaceLayoutTests {
    private func hiding(_ view: VizView, in layout: inout WorkspaceLayout) {
        var views = layout.views
        views.setHidden(view, true)
        layout.setViews(views)
    }

    @Test func hidingTheCurrentViewSwitchesToTheFirstShownOne() {
        var layout = WorkspaceLayout(treemapStyle: .flat)
        hiding(.flat, in: &layout)
        #expect(layout.view == .cushion)
        hiding(.cushion, in: &layout)
        #expect(layout.view == .sunburst)
        #expect(layout.treemapStyle == .cushion)
        // The last one shown stays.
        hiding(.sunburst, in: &layout)
        #expect(layout.views.visible == [.sunburst])
    }

    @Test func pickingAHiddenViewShowsItAgain() {
        var layout = WorkspaceLayout()
        hiding(.sunburst, in: &layout)
        layout.pick(.sunburst)
        #expect(layout.view == .sunburst)
        #expect(layout.views.visible == VizView.allCases)
    }

    @Test func aHiddenLaunchDefaultGivesWayToTheFirstShownView() {
        var layout = WorkspaceLayout(mode: .sunburst)
        hiding(.cushion, in: &layout)
        layout.openAtLaunch(.cushion)
        #expect(layout.view == .flat)
        #expect(layout.views.isHidden(.cushion))
        layout.openAtLaunch(nil)
        #expect(layout.view == .flat)
    }

    @Test func treemapListFollowsItsPositionAndHides() {
        var layout = WorkspaceLayout(listPosition: .leading)
        #expect(layout.showsLeadingList && !layout.showsBottomList)
        layout.setListShown(false)
        #expect(!layout.showsList)
        layout.placeList(.bottom)
        #expect(layout.showsBottomList && layout.listPosition == .bottom)
    }

    /// Each view remembers its own list; Sunburst's is opt-in and bottom-only.
    @Test func sunburstListIsBottomOnlyAndSeparate() {
        var layout = WorkspaceLayout(mode: .sunburst, listPosition: .leading)
        #expect(!layout.showsList)
        #expect(!layout.canPlaceList(.leading))
        layout.placeList(.leading)
        #expect(!layout.showsList)
        layout.placeList(.bottom)
        #expect(layout.showsBottomList && !layout.showsLeadingList)
        #expect(layout.listPosition == .leading)
        layout.setListShown(false)
        layout.pick(.cushion)
        #expect(layout.showsLeadingList)
    }
}
