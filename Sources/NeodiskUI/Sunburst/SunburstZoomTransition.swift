//
//  SunburstZoomTransition.swift
//  Neodisk
//
//  Draws the sunburst's drill transition (state and timeline in
//  NeodiskAppModel's SunburstZoomTransition): pure polar remapping over
//  already-styled segments, so tab colors, highlights, the colorblind
//  palette, and the free-space arc all carry through unchanged.
//

import CoreGraphics
import Foundation
import SwiftUI
import SunburstCore
import NeodiskAppModel

/// The transition frame: one scene per phase, no background, no stacked
/// layers. Segments draw in layout order — ancestors precede descendants
/// in the segment array, so the expanding focus disk covers its collapsing
/// ancestors.
struct SunburstZoomTransitionCanvas: View {
    let state: SunburstZoomTransitionState
    let presentation: SunburstZoomPresentation
    /// Tapered ring radii, matching the layout's — the remap bands its
    /// re-depthed arcs through these so the handoff to the real layout is an
    /// invisible cut.
    let metrics: SunburstRingMetrics

    var body: some View {
        Canvas { context, size in
            // One hatch brush per frame: stripe geometry is built lazily on
            // the first dataless arc and reused for the rest.
            let hatch = SunburstDatalessHatch(size: size)
            switch presentation.phase {
            case .zooming(let progress):
                guard let focus = state.focus else { return }
                drawRemapped(
                    state.animatedSegments,
                    focus: focus,
                    progress: progress,
                    hatch: hatch,
                    in: &context,
                    size: size
                )

            case .revealingIncoming(let alpha):
                drawIdentity(
                    state.incomingSegments,
                    alphaForDeepRings: alpha,
                    deeperThan: state.handoffFadeDepthThreshold,
                    hatch: hatch,
                    in: &context,
                    size: size
                )

            case .holdingPrevious:
                drawIdentity(
                    state.previousSegments,
                    alphaForDeepRings: 1,
                    deeperThan: Int.max,
                    hatch: hatch,
                    in: &context,
                    size: size
                )

            case .fadingOrphans(let alpha):
                if let focus = state.focus {
                    drawRemapped(
                        state.animatedSegments,
                        focus: focus,
                        progress: 1,
                        hatch: hatch,
                        in: &context,
                        size: size
                    )
                }
                // The orphaned rings sit in a band the remap leaves empty,
                // so this second pass never overlaps the first.
                drawIdentity(
                    state.previousSegments,
                    alphaForDeepRings: alpha,
                    deeperThan: state.handoffFadeDepthThreshold,
                    onlyDeepRings: true,
                    hatch: hatch,
                    in: &context,
                    size: size
                )
            }
        }
    }

    private func drawRemapped(
        _ segments: [SunburstSegment],
        focus: SunburstSegment,
        progress: Double,
        hatch: SunburstDatalessHatch,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for segment in segments {
            let segmentOpacity = SunburstZoomGeometry.opacity(
                for: segment,
                focus: focus,
                rawProgress: progress
            )
            guard segmentOpacity > 0.001 else { continue }

            context.opacity = segmentOpacity
            draw(
                segment,
                arc: SunburstZoomGeometry.arc(for: segment, focus: focus, progress: progress, metrics: metrics),
                effectiveDepth: SunburstZoomGeometry.effectiveDepth(
                    for: segment,
                    focus: focus,
                    progress: progress
                ),
                hatch: hatch,
                in: &context,
                size: size
            )
        }
    }

    private func drawIdentity(
        _ segments: [SunburstSegment],
        alphaForDeepRings: Double,
        deeperThan threshold: Int,
        onlyDeepRings: Bool = false,
        hatch: SunburstDatalessHatch,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for segment in segments {
            let isDeepRing = segment.depth > threshold
            if onlyDeepRings, !isDeepRing { continue }

            let segmentOpacity = isDeepRing ? alphaForDeepRings : 1
            guard segmentOpacity > 0.001 else { continue }

            context.opacity = segmentOpacity
            draw(
                segment,
                arc: SunburstZoomGeometry.identityArc(for: segment),
                effectiveDepth: Double(segment.depth),
                hatch: hatch,
                in: &context,
                size: size
            )
        }
    }

    private func draw(
        _ segment: SunburstSegment,
        arc: SunburstZoomArc,
        effectiveDepth: Double,
        hatch: SunburstDatalessHatch,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard arc.isDrawable else { return }

        let path = SunburstRenderer.path(for: arc, in: size)
        let style = SunburstChartStyler.baseStyle(for: segment, effectiveDepth: effectiveDepth)
        context.fill(path, with: .color(style.fillColor))
        context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
        if segment.isDataless {
            // The copied context keeps the caller's opacity, so the hatch
            // fades with its arc during the transition.
            hatch.draw(over: path, in: context)
        }
    }
}
