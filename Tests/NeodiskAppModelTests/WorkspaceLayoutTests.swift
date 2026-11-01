import Testing
import TreemapKit
@testable import NeodiskAppModel

struct WorkspaceLayoutTests {
    @Test func hidingTheCurrentViewSwitchesToTheFirstShownOne() {
        var layout = WorkspaceLayout(treemapStyle: .flat)
        layout.setHidden(.flat, true)
        #expect(layout.view == .cushion)
        layout.setHidden(.cushion, true)
        #expect(layout.view == .sunburst)
        #expect(layout.treemapStyle == .cushion)
        // The last one shown stays.
        layout.setHidden(.sunburst, true)
        #expect(layout.views.visible == [.sunburst])
    }

    @Test func pickingAHiddenViewShowsItAgain() {
        var layout = WorkspaceLayout()
        layout.setHidden(.sunburst, true)
        layout.pick(.sunburst)
        #expect(layout.view == .sunburst)
        #expect(layout.views.visible == VizView.allCases)
    }

    @Test func aHiddenLaunchDefaultGivesWayToTheFirstShownView() {
        var layout = WorkspaceLayout(mode: .sunburst)
        layout.setHidden(.cushion, true)
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
