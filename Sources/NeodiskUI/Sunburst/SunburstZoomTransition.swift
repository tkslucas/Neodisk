//
//  SunburstZoomTransition.swift
//  Neodisk
//
//  DaisyDisk-style drill transition for the sunburst: the clicked segment's
//  arc sweeps open to the full circle while its band morphs into the center
//  disk, its descendants shift up one ring per level, and everything outside
//  the arc collapses to zero width; zooming out plays the exact reverse on
//  the incoming parent layout. Pure polar remapping over already-styled
//  segments, so tab colors, highlights, the colorblind palette, and the
//  free-space arc all carry through unchanged.
//

import CoreGraphics
import Foundation
import SwiftUI
import SunburstCore

/// View-local state for one drill transition, owned by SunburstChartView.
/// All rendering derives deterministically from this plus the current frame
/// date (via SunburstZoomPresentation), so the animation needs no SwiftUI
/// animation plumbing — a TimelineView redraws it each frame.
struct SunburstZoomTransitionState {
    enum Direction {
        case zoomIn
        case zoomOut
    }

    static let geometryDuration: TimeInterval = 0.4
    static let handoffDuration: TimeInterval = 0.14
    /// Give up and fall back to the normal pending UI if the target layout
    /// has not landed by then (huge folders, slow disks).
    static let waitingForLayoutTimeout: TimeInterval = 1.5

    let id = UUID()
    let direction: Direction
    let startDate: Date
    /// Segments animated through the polar remap: the outgoing layout for
    /// zoom-in; the incoming parent layout for zoom-out (set once it lands).
    var animatedSegments: [SunburstSegment]
    /// The drilled node's segment within `animatedSegments`' layout.
    var focus: SunburstSegment?
    /// Zoom-out: the outgoing drilled-in chart, drawn as-is until the parent
    /// layout lands (its orphaned outermost rings then fade at the handoff).
    var previousSegments: [SunburstSegment]
    /// Zoom-out: the outgoing root, resolved to `focus` in the new layout.
    let previousRootID: String?
    var layoutReadyDate: Date?
    /// Zoom-in: the landed target layout the handoff reveals.
    var incomingSegments: [SunburstSegment] = []
    /// Rings deeper than this have no remapped counterpart — the remap can
    /// only carry what the outgoing/incoming layout drew. They alpha-fade
    /// at the handoff (in for zoom-in, out for zoom-out) instead of popping.
    var handoffFadeDepthThreshold = Int.max

    static func zoomIn(
        segments: [SunburstSegment],
        focus: SunburstSegment,
        startDate: Date = Date()
    ) -> SunburstZoomTransitionState {
        SunburstZoomTransitionState(
            direction: .zoomIn,
            startDate: startDate,
            animatedSegments: segments,
            focus: focus,
            previousSegments: [],
            previousRootID: nil,
            layoutReadyDate: nil
        )
    }

    static func zoomOut(
        previousSegments: [SunburstSegment],
        previousRootID: String,
        startDate: Date = Date()
    ) -> SunburstZoomTransitionState {
        SunburstZoomTransitionState(
            direction: .zoomOut,
            startDate: startDate,
            animatedSegments: [],
            focus: nil,
            previousSegments: previousSegments,
            previousRootID: previousRootID,
            layoutReadyDate: nil
        )
    }
}

/// What the transition canvas shows this frame. Exactly one scene draws at
/// a time — the phases never stack two full arc passes, so alpha-blended
/// fills can't double up (a brightness flash), and nothing paints a
/// background, so the pane behind the chart shows through untouched.
/// Phase boundaries land on pixel-identical content: the remap preserves
/// each segment's angular proportions, colors, and depth fade, so switching
/// between a settled remap and the real layout is an invisible cut. The
/// only rings that differ — deeper than `handoffFadeDepthThreshold`, which
/// the remap could not carry — alpha-fade as a single layer over the pane.
enum SunburstZoomPhase: Equatable {
    /// Segments remapped toward (zoom-in) or away from (zoom-out) the focus.
    case zooming(progress: Double)
    /// Zoom-in handoff: the landed target layout, its uncarried deep rings
    /// fading in ("new rings radiate") — everything else already matches
    /// the settled remap pixel-for-pixel.
    case revealingIncoming(alpha: Double)
    /// Zoom-out, parent layout still loading: the outgoing chart, held.
    case holdingPrevious
    /// Zoom-out handoff: the remapped parent held fully zoomed (matching
    /// the outgoing chart) while the outgoing chart's orphaned outermost
    /// rings fade away before the reverse motion starts.
    case fadingOrphans(alpha: Double)
}

/// Everything one frame of the transition needs, computed from the state
/// and the frame date.
struct SunburstZoomPresentation {
    let phase: SunburstZoomPhase
    let isFinished: Bool

    init(state: SunburstZoomTransitionState, now: Date) {
        let geometryDuration = SunburstZoomTransitionState.geometryDuration
        let handoffDuration = SunburstZoomTransitionState.handoffDuration

        switch state.direction {
        case .zoomIn:
            let elapsed = now.timeIntervalSince(state.startDate)

            // The handoff waits for both the motion to fully settle and the
            // real layout to exist; until then the remap holds the zoomed
            // frame.
            if let layoutReadyDate = state.layoutReadyDate {
                let handoffStart = max(
                    state.startDate.addingTimeInterval(geometryDuration),
                    layoutReadyDate
                )
                let handoffElapsed = now.timeIntervalSince(handoffStart)
                if handoffElapsed >= 0 {
                    phase = .revealingIncoming(
                        alpha: min(handoffElapsed / handoffDuration, 1)
                    )
                    isFinished = handoffElapsed >= handoffDuration
                    return
                }
            }

            phase = .zooming(progress: min(max(elapsed / geometryDuration, 0), 1))
            isFinished = state.layoutReadyDate == nil
                && elapsed > geometryDuration
                    + SunburstZoomTransitionState.waitingForLayoutTimeout

        case .zoomOut:
            guard let layoutReadyDate = state.layoutReadyDate, state.focus != nil else {
                phase = .holdingPrevious
                isFinished = now.timeIntervalSince(state.startDate)
                    > SunburstZoomTransitionState.waitingForLayoutTimeout
                return
            }

            let elapsed = now.timeIntervalSince(layoutReadyDate)
            if elapsed < handoffDuration {
                phase = .fadingOrphans(alpha: 1 - (elapsed / handoffDuration))
                isFinished = false
            } else {
                let reverseElapsed = elapsed - handoffDuration
                phase = .zooming(
                    progress: 1 - min(reverseElapsed / geometryDuration, 1)
                )
                // Ends pixel-identical to the real layout below — the
                // teardown when this flips is an invisible cut.
                isFinished = reverseElapsed >= geometryDuration
            }
        }
    }
}

/// The transition frame: one scene per phase, no background, no stacked
/// layers. Segments draw in layout order — ancestors precede descendants
/// in the segment array, so the expanding focus disk covers its collapsing
/// ancestors.
struct SunburstZoomTransitionCanvas: View {
    let state: SunburstZoomTransitionState
    let presentation: SunburstZoomPresentation

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
                arc: SunburstZoomGeometry.arc(for: segment, focus: focus, progress: progress),
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
