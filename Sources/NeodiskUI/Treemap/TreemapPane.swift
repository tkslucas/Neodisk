// SwiftUI wrapper pushing model inputs into TreemapController. Gestures mutate the CALayer directly, never
// SwiftUI state; the overlay only draws the hover tooltip.

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
        controller.setInputs(
            snapshot: model.coordinator.snapshot,
            rootID: model.effectiveRootID,
            catalog: model.kinds.catalog,
            style: model.treemapStyle,
            colorMode: model.vizColorMode,
            highlight: model.vizHighlight,
            expandedAggregateIDs: model.expandedAggregateIDs,
            // Volume-wide space hides once zoomed into a subfolder; the treemap also gates it on the Settings toggle.
            freeSpaceBytes: model.zoomRootID == nil ? model.freeSpace.treemapFreeSpaceBytes : nil,
            hiddenSpaceBytes: model.zoomRootID == nil ? model.freeSpace.treemapHiddenSpaceBytes : nil,
            includingCloudOnly: model.showsCloudOnlyFiles,
            palette: model.vizPalette,
            labelScale: CGFloat(model.textScale)
        )
        controller.setSelectedNode(model.selectedNodeID)
    }
}
