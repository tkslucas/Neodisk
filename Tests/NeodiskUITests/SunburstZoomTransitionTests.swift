//
//  SunburstZoomTransitionTests.swift
//  Neodisk
//
//  The DaisyDisk-style drill zoom: polar remapping of segments toward the
//  focused arc (focus → center disk, descendants re-banded, outsiders
//  collapsed) and the per-frame presentation state machine.
//

import SunburstCore
import CoreGraphics
import Foundation
import Testing
@testable import NeodiskUI

@Suite struct SunburstZoomTransitionTests {
    private let ringWidth: Double = (0.98 - SunburstLayout.centerRadius) / 6

    private func makeSegment(
        id: String,
        depth: Int,
        startRadians: Double,
        endRadians: Double
    ) -> SunburstSegment {
        let inner = SunburstLayout.centerRadius + (Double(depth) * ringWidth)
        return SunburstSegment(
            id: id,
            nodeID: id,
            label: id,
            startAngle: startRadians,
            endAngle: endRadians,
            innerRadius: inner,
            outerRadius: inner + ringWidth - SunburstLayout.ringGap,
            depth: depth,
            colorToken: .single(id: id, role: .normal),
            totalSize: 1,
            isAggregate: false
        )
    }

    // MARK: - Zoomed geometry

    @Test func focusBecomesCenterDisk() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)

        let arc = SunburstZoomGeometry.zoomedArc(for: focus, focus: focus)

        #expect(arc.startRadians == 0)
        #expect(abs(arc.endRadians - .pi * 2) < 0.0001)
        #expect(arc.innerRadius == 0)
        #expect(arc.outerRadius == SunburstLayout.centerRadius)
    }

    @Test func descendantSpanningFocusArcBecomesTopRing() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let child = makeSegment(id: "child", depth: 1, startRadians: 1, endRadians: 2)

        let arc = SunburstZoomGeometry.zoomedArc(for: child, focus: focus)

        #expect(abs(arc.startRadians) < 0.0001)
        #expect(abs(arc.endRadians - .pi * 2) < 0.0001)
        #expect(abs(arc.innerRadius - SunburstLayout.centerRadius) < 0.0001)
        #expect(abs(arc.outerRadius - (SunburstLayout.centerRadius + ringWidth - SunburstLayout.ringGap)) < 0.0001)
    }

    @Test func descendantAnglesRemapProportionally() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 3)
        let child = makeSegment(id: "child", depth: 1, startRadians: 1.5, endRadians: 2)

        let arc = SunburstZoomGeometry.zoomedArc(for: child, focus: focus)

        #expect(abs(arc.startRadians - (.pi * 2 * 0.25)) < 0.0001)
        #expect(abs(arc.endRadians - (.pi * 2 * 0.5)) < 0.0001)
    }

    @Test func segmentOutsideFocusArcCollapsesToZeroWidth() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let sibling = makeSegment(id: "sibling", depth: 0, startRadians: 3, endRadians: 4)

        let arc = SunburstZoomGeometry.zoomedArc(for: sibling, focus: focus)

        #expect(abs(arc.endRadians - arc.startRadians) < 0.0001)
        #expect(!arc.isDrawable)
    }

    @Test func ancestorShrinksIntoCenter() {
        let focus = makeSegment(id: "focus", depth: 2, startRadians: 1, endRadians: 2)
        let ancestor = makeSegment(id: "ancestor", depth: 0, startRadians: 0.5, endRadians: 3)

        let arc = SunburstZoomGeometry.zoomedArc(for: ancestor, focus: focus)

        // Ancestors end up inside the hole, covered by the focus disk.
        #expect(arc.outerRadius <= SunburstLayout.centerRadius)
        #expect(arc.innerRadius == 0)
    }

    @Test func progressZeroIsIdentity() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let child = makeSegment(id: "child", depth: 1, startRadians: 1.2, endRadians: 1.7)

        let arc = SunburstZoomGeometry.arc(for: child, focus: focus, progress: 0)

        #expect(arc == SunburstZoomGeometry.identityArc(for: child))
    }

    @Test func effectiveDepthBlendsTowardRebandedDepth() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let child = makeSegment(id: "child", depth: 2, startRadians: 1.2, endRadians: 1.7)

        #expect(SunburstZoomGeometry.effectiveDepth(for: child, focus: focus, progress: 0) == 2)
        #expect(SunburstZoomGeometry.effectiveDepth(for: child, focus: focus, progress: 1) == 1)
        let midway = SunburstZoomGeometry.effectiveDepth(for: child, focus: focus, progress: 0.5)
        #expect(midway > 1 && midway < 2)
    }

    // MARK: - Staggered timing

    @Test func collapsingShellFinishesEarly() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let sibling = makeSegment(id: "sibling", depth: 0, startRadians: 3, endRadians: 4)

        let arc = SunburstZoomGeometry.arc(
            for: sibling,
            focus: focus,
            progress: SunburstZoomGeometry.collapseFinishFraction
        )

        #expect(arc == SunburstZoomGeometry.zoomedArc(for: sibling, focus: focus))
    }

    @Test func descendantsHoldStillThroughTheStartDelay() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let child = makeSegment(id: "child", depth: 1, startRadians: 1.2, endRadians: 1.7)

        let arc = SunburstZoomGeometry.arc(
            for: child,
            focus: focus,
            progress: SunburstZoomGeometry.descendantStartFraction * 0.9
        )

        #expect(arc == SunburstZoomGeometry.identityArc(for: child))
    }

    @Test func descendantsLagTheFocusMidTransition() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let child = makeSegment(id: "child", depth: 1, startRadians: 1, endRadians: 2)

        let focusProgress = SunburstZoomGeometry.timedProgress(for: focus, focus: focus, rawProgress: 0.5)
        let childProgress = SunburstZoomGeometry.timedProgress(for: child, focus: focus, rawProgress: 0.5)

        #expect(childProgress < focusProgress)
        #expect(SunburstZoomGeometry.timedProgress(for: child, focus: focus, rawProgress: 1) == 1)
    }

    @Test func shellFadesOutBeforeItsCollapseCompletes() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let sibling = makeSegment(id: "sibling", depth: 0, startRadians: 3, endRadians: 4)

        #expect(SunburstZoomGeometry.opacity(for: sibling, focus: focus, rawProgress: 0) == 1)

        // Fully transparent once its timed progress hits the fade fraction —
        // strictly before the collapse itself finishes.
        let fadeEnd = SunburstZoomGeometry.collapseFinishFraction * 0.9
        let lateOpacity = SunburstZoomGeometry.opacity(for: sibling, focus: focus, rawProgress: fadeEnd)
        #expect(lateOpacity < 0.1)
        #expect(SunburstZoomGeometry.opacity(
            for: sibling,
            focus: focus,
            rawProgress: SunburstZoomGeometry.collapseFinishFraction
        ) == 0)
    }

    @Test func descendantsStayOpaque() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let child = makeSegment(id: "child", depth: 1, startRadians: 1.2, endRadians: 1.7)

        for progress in [0.0, 0.3, 0.6, 1.0] {
            #expect(SunburstZoomGeometry.opacity(for: child, focus: focus, rawProgress: progress) == 1)
        }
    }

    @Test func focusHoldsThroughItsSweepThenFadesBeforeSealing() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)

        // Opaque while the arc is still sweeping open (timed progress below
        // the fade window)...
        #expect(SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 0) == 1)
        #expect(SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 0.3) == 1)

        // ...and fully gone by the end, before the band seals into a disk.
        #expect(SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 1) == 0)

        // The fade is monotonic through the window.
        let mid = SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 0.6)
        #expect(mid > 0 && mid < 1)
    }

    @Test func deepSegmentOutsideFocusWedgeCollapsesWithTheShell() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let nephew = makeSegment(id: "nephew", depth: 1, startRadians: 3, endRadians: 3.5)

        let shellProgress = SunburstZoomGeometry.timedProgress(
            for: nephew,
            focus: focus,
            rawProgress: SunburstZoomGeometry.collapseFinishFraction
        )

        #expect(shellProgress == 1)
    }

    // MARK: - Presentation

    @Test func zoomInHoldsTheRemapUntilLayoutLands() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let state = SunburstZoomTransitionState.zoomIn(
            segments: [focus],
            focus: focus,
            startDate: start
        )

        let midway = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(SunburstZoomTransitionState.geometryDuration / 2)
        )
        #expect(midway.phase == .zooming(progress: 0.5))
        #expect(!midway.isFinished)

        let held = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(SunburstZoomTransitionState.geometryDuration * 2)
        )
        #expect(held.phase == .zooming(progress: 1))
        #expect(!held.isFinished)
    }

    @Test func zoomInRevealsTheIncomingLayoutAfterTheMotionSettles() {
        let focus = makeSegment(id: "focus", depth: 0, startRadians: 1, endRadians: 2)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var state = SunburstZoomTransitionState.zoomIn(
            segments: [focus],
            focus: focus,
            startDate: start
        )
        state.layoutReadyDate = start.addingTimeInterval(0.05)

        // The handoff waits for the motion to settle even though the layout
        // landed early — no jump from a mid-flight remap to the real thing.
        let midway = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(SunburstZoomTransitionState.geometryDuration / 2)
        )
        #expect(midway.phase == .zooming(progress: 0.5))

        let revealing = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(
                SunburstZoomTransitionState.geometryDuration
                    + (SunburstZoomTransitionState.handoffDuration / 2)
            )
        )
        #expect(revealing.phase == .revealingIncoming(alpha: 0.5))
        #expect(!revealing.isFinished)

        let end = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(
                SunburstZoomTransitionState.geometryDuration
                    + SunburstZoomTransitionState.handoffDuration
            )
        )
        #expect(end.phase == .revealingIncoming(alpha: 1))
        #expect(end.isFinished)
    }

    @Test func zoomOutWaitsForParentLayoutThenReverses() {
        let focus = makeSegment(id: "old-root", depth: 0, startRadians: 1, endRadians: 2)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var state = SunburstZoomTransitionState.zoomOut(
            previousSegments: [focus],
            previousRootID: "old-root",
            startDate: start
        )

        let waiting = SunburstZoomPresentation(state: state, now: start.addingTimeInterval(0.2))
        #expect(waiting.phase == .holdingPrevious)
        #expect(!waiting.isFinished)

        state.animatedSegments = [focus]
        state.focus = focus
        state.layoutReadyDate = start.addingTimeInterval(0.2)

        // The outgoing chart's orphaned outermost rings fade over the held
        // remap before any motion starts.
        let handoff = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(0.2 + (SunburstZoomTransitionState.handoffDuration / 2))
        )
        #expect(handoff.phase == .fadingOrphans(alpha: 0.5))
        #expect(!handoff.isFinished)

        let reversing = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(
                0.2 + SunburstZoomTransitionState.handoffDuration
                    + (SunburstZoomTransitionState.geometryDuration / 2)
            )
        )
        #expect(reversing.phase == .zooming(progress: 0.5))
        #expect(!reversing.isFinished)

        let done = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(
                0.2 + SunburstZoomTransitionState.handoffDuration
                    + SunburstZoomTransitionState.geometryDuration
            )
        )
        #expect(done.phase == .zooming(progress: 0))
        #expect(done.isFinished)
    }

    @Test func zoomOutTimesOutWhenParentLayoutNeverLands() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let state = SunburstZoomTransitionState.zoomOut(
            previousSegments: [],
            previousRootID: "old-root",
            startDate: start
        )

        let stuck = SunburstZoomPresentation(
            state: state,
            now: start.addingTimeInterval(SunburstZoomTransitionState.waitingForLayoutTimeout + 0.1)
        )
        #expect(stuck.isFinished)
    }
}
