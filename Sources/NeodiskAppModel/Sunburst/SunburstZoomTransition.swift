// The sunburst drill transition's state and per-frame phase, shared by both apps; the geometry lives in
// SunburstCore's SunburstZoomGeometry and each app draws the frames.

import Foundation
import SunburstCore

/// Rendering derives deterministically from this plus the frame date, so the apps only need a per-frame redraw.
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
    /// Rings the remap can't carry alpha-fade at the handoff instead of popping.
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

/// Exactly one scene draws at a time so alpha fills never double up into a flash. Phase boundaries land on
/// pixel-identical content, so each switch is an invisible cut.
package enum SunburstZoomPhase: Equatable, Sendable {
    /// Segments remapped toward (zoom-in) or away from (zoom-out) the focus.
    case zooming(progress: Double)
    /// The landed layout with its uncarried deep rings fading in; the rest already matches the remap.
    case revealingIncoming(alpha: Double)
    /// Zoom-out, parent layout still loading: the outgoing chart, held.
    case holdingPrevious
    /// The remapped parent held zoomed while the outgoing chart's orphaned outer rings fade before the reverse.
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

            // Waits for the motion to settle and the real layout to exist.
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
    /// Ring `d` lands `focus.depth + 1` rings shallower, so deeper rings have no counterpart and fade instead.
    package static func handoffFadeDepthThreshold(
        animatedSegments: [SunburstSegment],
        focus: SunburstSegment
    ) -> Int {
        let maxAnimatedDepth = animatedSegments.map(\.depth).max() ?? 0
        return maxAnimatedDepth - focus.depth - 1
    }
}
