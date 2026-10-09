//
//  SunburstZoomTransition.swift
//  NeodiskAppModel
//
//  The sunburst's drill transition timeline, shared by both apps: the
//  clicked segment's arc sweeps open to the full circle while its band
//  morphs into the center disk, its descendants shift up one ring per
//  level, and everything outside the arc collapses to zero width; zooming
//  out plays the exact reverse on the incoming parent layout. This file is
//  the state and its per-frame phase; the geometry is SunburstCore's
//  SunburstZoomGeometry, and each app draws the frames with its toolkit.
//

import Foundation
import SunburstCore

/// View-local state for one drill transition, owned by the sunburst view
/// (SunburstChartView on the Mac, SunburstView on Linux). All rendering
/// derives deterministically from this plus the current frame date (via
/// SunburstZoomPresentation), so the apps only need a per-frame redraw — a
/// TimelineView on the Mac, a frame-clock tick on Linux.
package struct SunburstZoomTransitionState: Sendable {
    package enum Direction: Sendable {
        case zoomIn
        case zoomOut
    }

    package static let geometryDuration: TimeInterval = 0.4
    package static let handoffDuration: TimeInterval = 0.14
    /// Give up and fall back to the normal pending UI if the target layout
    /// has not landed by then (huge folders, slow disks).
    package static let waitingForLayoutTimeout: TimeInterval = 1.5

    package let id = UUID()
    package let direction: Direction
    package let startDate: Date
    /// Segments animated through the polar remap: the outgoing layout for
    /// zoom-in; the incoming parent layout for zoom-out (set once it lands).
    package var animatedSegments: [SunburstSegment]
    /// The drilled node's segment within `animatedSegments`' layout.
    package var focus: SunburstSegment?
    /// Zoom-out: the outgoing drilled-in chart, drawn as-is until the parent
    /// layout lands (its orphaned outermost rings then fade at the handoff).
    package var previousSegments: [SunburstSegment]
    /// Zoom-out: the outgoing root, resolved to `focus` in the new layout.
    package let previousRootID: String?
    package var layoutReadyDate: Date?
    /// Zoom-in: the landed target layout the handoff reveals.
    package var incomingSegments: [SunburstSegment] = []
    /// Rings deeper than this have no remapped counterpart — the remap can
    /// only carry what the outgoing/incoming layout drew. They alpha-fade
    /// at the handoff (in for zoom-in, out for zoom-out) instead of popping.
    package var handoffFadeDepthThreshold = Int.max

    package static func zoomIn(
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

    package static func zoomOut(
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
package enum SunburstZoomPhase: Equatable, Sendable {
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
package struct SunburstZoomPresentation: Sendable {
    package let phase: SunburstZoomPhase
    package let isFinished: Bool

    package init(state: SunburstZoomTransitionState, now: Date) {
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

extension SunburstZoomTransitionState {
    /// The deepest ring the remap can carry: animated ring `d` lands
    /// `focus.depth + 1` rings shallower, so anything in the other layout
    /// past this depth has no remapped counterpart and alpha-fades at the
    /// handoff (incoming deep rings on zoom-in, the outgoing chart's
    /// orphaned outermost rings on zoom-out).
    package static func handoffFadeDepthThreshold(
        animatedSegments: [SunburstSegment],
        focus: SunburstSegment
    ) -> Int {
        let maxAnimatedDepth = animatedSegments.map(\.depth).max() ?? 0
        return maxAnimatedDepth - focus.depth - 1
    }
}
