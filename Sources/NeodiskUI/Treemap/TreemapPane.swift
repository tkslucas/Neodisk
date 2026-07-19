//
//  TreemapPane.swift
//  Neodisk
//
//  SwiftUI wrapper around the AppKit treemap view: pushes render inputs from
//  the view model into the TreemapController on every model change and lets
//  the controller/view pair handle everything else (rendering, gestures,
//  hover, selection, context menu). A SwiftUI overlay adds the floating hover
//  tooltip on top, fed by the controller's hover/gesture callbacks — the
//  gestures themselves still mutate the CALayer directly, never SwiftUI state.
//

import SwiftUI

struct TreemapPane: View {
    let model: NeodiskViewModel

    /// Cursor position in the pane (flipped/top-left, matching the treemap
    /// NSView), or nil when not over a cell. Drives the tooltip's placement.
    @State private var hoverPoint: CGPoint?
    /// True while a pan/zoom gesture moves the map; the tooltip hides.
    @State private var isGesturing = false

    var body: some View {
        GeometryReader { geometry in
            TreemapRepresentable(
                model: model,
                onHoverPoint: { hoverPoint = $0 },
                onGestureActiveChange: { active in
                    isGesturing = active
                    // Drop the stale point so the tooltip only returns once the
                    // pointer moves again over a (possibly new) cell.
                    if active { hoverPoint = nil }
                }
            )
            .overlay(alignment: .topLeading) {
                if !isGesturing, let hoverPoint,
                   let data = VizHoverTooltipData.current(in: model) {
                    VizHoverTooltipLayer(
                        data: data,
                        location: hoverPoint,
                        paneSize: geometry.size
                    )
                }
            }
        }
    }
}

private struct TreemapRepresentable: NSViewRepresentable {
    let model: NeodiskViewModel
    let onHoverPoint: (CGPoint?) -> Void
    let onGestureActiveChange: (Bool) -> Void

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
        controller.onHoverPoint = onHoverPoint
        controller.onGestureActiveChange = onGestureActiveChange
        let colorMode = model.treemapColorMode
        // Branch mode has no legend on screen, so no tab highlight reaches
        // the map — mirroring the sunburst's hidden-panel behavior.
        let highlight: TreemapHighlight? = colorMode == .branch ? nil : model.treemapHighlight
        controller.setInputs(
            snapshot: model.coordinator.snapshot,
            rootID: model.effectiveRootID,
            catalog: model.kinds.catalog,
            style: model.treemapStyle,
            colorMode: colorMode,
            highlight: highlight,
            expandedAggregateIDs: model.expandedAggregateIDs,
            // Free and hidden space belong to the volume as a whole; hide
            // them once the user zooms into a subfolder. The treemap gates
            // them behind the Settings toggle (the sunburst always shows
            // them) — hence the treemap-specific accessors.
            freeSpaceBytes: model.zoomRootID == nil ? model.freeSpace.treemapFreeSpaceBytes : nil,
            hiddenSpaceBytes: model.zoomRootID == nil ? model.freeSpace.treemapHiddenSpaceBytes : nil,
            includingCloudOnly: model.showsCloudOnlyFiles,
            palette: model.vizPalette
        )
        controller.setSelectedNode(model.selectedNodeID)
    }
}
