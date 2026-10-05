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
            .overlay(alignment: .top) {
                if model.showsTokens {
                    TokenCountingBadge(phase: model.tokens.phase)
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
        // Token mode has no free or hidden space to show.
        let showsVolumeSpace = model.zoomRootID == nil && !model.showsTokenWeights
        controller.setInputs(
            snapshot: model.vizSnapshot,
            rootID: model.effectiveRootID,
            catalog: model.kinds.catalog,
            style: model.treemapStyle,
            colorMode: model.vizColorMode,
            highlight: model.vizHighlight,
            expandedAggregateIDs: model.expandedAggregateIDs,
            // Free and hidden space belong to the volume as a whole; hide
            // them once the user zooms into a subfolder. The treemap gates
            // them behind the Settings toggle (the sunburst always shows
            // them) — hence the treemap-specific accessors.
            freeSpaceBytes: showsVolumeSpace ? model.freeSpace.treemapFreeSpaceBytes : nil,
            hiddenSpaceBytes: showsVolumeSpace ? model.freeSpace.treemapHiddenSpaceBytes : nil,
            includingCloudOnly: model.showsCloudOnlyFiles,
            palette: model.vizPalette,
            labelScale: CGFloat(model.textScale)
        )
        controller.setSelectedNode(model.selectedNodeID)
    }
}

/// Floats over the map while token mode still shows byte sizes.
private struct TokenCountingBadge: View {
    let phase: TokenModel.Phase

    var body: some View {
        if let text {
            Text(text)
                .neoFont(11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }

    private var text: String? {
        switch phase {
        case .idle, .ready:
            return nil
        case .waitingForScan:
            return NSLocalizedString("Tokens are counted when the scan finishes", comment: "Token mode, waiting for the scan")
        case .counting(let done, let total):
            return String(
                format: NSLocalizedString("Counting tokens… %@ of %@ files", comment: "Token mode progress"),
                done.formatted(), total.formatted()
            )
        }
    }
}
