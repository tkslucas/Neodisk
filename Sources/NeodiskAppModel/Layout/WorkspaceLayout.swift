// What the workspace shows: the visualization, the views the toolbar picker offers, and each view's file list.
// Both apps keep it in their settings; the rules live here.

import TreemapKit

package struct WorkspaceLayout: Equatable {
    package var mode: VizViewMode
    /// Kept while Sunburst shows, for the trip back.
    package var treemapStyle: TreemapStyle
    package private(set) var views: ItemLayout<VizView>
    package var listPosition: OutlinePosition
    package var showsListWithTreemap: Bool
    /// Sunburst's list is opt-in and bottom-only, to keep the chart wide.
    package var showsListBelowSunburst: Bool

    package init(
        mode: VizViewMode = .treemap,
        treemapStyle: TreemapStyle = .cushion,
        views: ItemLayout<VizView> = ItemLayout(),
        listPosition: OutlinePosition = .bottom,
        showsListWithTreemap: Bool = true,
        showsListBelowSunburst: Bool = false
    ) {
        self.mode = mode
        self.treemapStyle = treemapStyle
        self.views = views
        self.listPosition = listPosition
        self.showsListWithTreemap = showsListWithTreemap
        self.showsListBelowSunburst = showsListBelowSunburst
    }

    package var view: VizView { VizView(mode: mode, style: treemapStyle) }

    /// Picking a hidden view (the View menu, a dev hook) shows it in the picker again.
    package mutating func pick(_ view: VizView) {
        views.setHidden(view, false)
        open(view)
    }

    /// Hiding the current view switches to the first one still shown.
    package mutating func setViews(_ layout: ItemLayout<VizView>) {
        views = layout
        open(layout.shown(view))
    }

    /// A hidden launch default gives way to the first shown view; nil keeps the last one.
    package mutating func openAtLaunch(_ view: VizView?) {
        open(views.shown(view ?? self.view))
    }

    private mutating func open(_ view: VizView) {
        mode = view.mode
        if let style = view.treemapStyle { treemapStyle = style }
    }

    // MARK: File list

    package var showsLeadingList: Bool {
        mode == .treemap && showsListWithTreemap && listPosition == .leading
    }

    package var showsBottomList: Bool {
        mode == .sunburst ? showsListBelowSunburst : showsListWithTreemap && listPosition == .bottom
    }

    /// The current view's list: each view remembers its own.
    package var showsList: Bool { showsLeadingList || showsBottomList }

    package func showsList(at position: OutlinePosition) -> Bool {
        position == .leading ? showsLeadingList : showsBottomList
    }

    package func canPlaceList(_ position: OutlinePosition) -> Bool {
        mode == .treemap || position == .bottom
    }

    package mutating func setListShown(_ shown: Bool) {
        if mode == .sunburst {
            showsListBelowSunburst = shown
        } else {
            showsListWithTreemap = shown
        }
    }

    /// Shows the list there.
    package mutating func placeList(_ position: OutlinePosition) {
        guard canPlaceList(position) else { return }
        if mode == .treemap { listPosition = position }
        setListShown(true)
    }
}
