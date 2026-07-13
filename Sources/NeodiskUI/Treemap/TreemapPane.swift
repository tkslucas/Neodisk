//
//  TreemapPane.swift
//  Neodisk
//
//  SwiftUI wrapper around the AppKit treemap view: pushes render inputs from
//  the view model into the TreemapController on every model change and lets
//  the controller/view pair handle everything else (rendering, gestures,
//  hover, selection, context menu).
//

import SwiftUI

struct TreemapPane: NSViewRepresentable {
    let model: NeodiskViewModel

    @MainActor
    final class Coordinator {
        let controller = TreemapController()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TreemapNSView {
        TreemapNSView(controller: context.coordinator.controller)
    }

    func updateNSView(_ nsView: TreemapNSView, context: Context) {
        let controller = context.coordinator.controller
        controller.model = model
        controller.setInputs(
            snapshot: model.coordinator.snapshot,
            rootID: model.effectiveRootID,
            catalog: model.kinds.catalog,
            colorMode: model.treemapColorMode,
            highlight: model.treemapHighlight,
            expandedAggregateIDs: model.expandedAggregateIDs,
            // Free and hidden space belong to the volume as a whole; hide
            // them once the user zooms into a subfolder. The treemap gates
            // them behind the Settings toggle (the sunburst always shows
            // them) — hence the treemap-specific accessors.
            freeSpaceBytes: model.zoomRootID == nil ? model.treemapFreeSpaceBytes : nil,
            hiddenSpaceBytes: model.zoomRootID == nil ? model.treemapHiddenSpaceBytes : nil,
            includingCloudOnly: model.showsCloudOnlyFiles,
            palette: model.vizPalette
        )
        controller.setSelectedNode(model.selectedNodeID)
    }
}
