// Polar hit-testing: ring banding (gap included), clockwise-from-12 angles, gaps and the center hole.

import Foundation
import SunburstCore
import Testing
@testable import NeodiskAppModel

private func segment(
    _ id: String,
    from start: Double,
    to end: Double,
    depth: Int,
    inner: Double,
    outer: Double
) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: id,
        label: id,
        startAngle: start,
        endAngle: end,
        innerRadius: inner,
        outerRadius: outer,
        depth: depth,
        colorToken: SunburstColorToken(midpoint: 0, depth: depth + 1, role: .normal),
        totalSize: 1,
        isAggregate: false
    )
}

@Suite struct SunburstHitTestTests {
    // Ring 0 leaves its last quarter (9 to 12 o'clock) empty; ring 1 is one full-circle arc.
    private let a = segment("a", from: 0, to: .pi, depth: 0, inner: 0.22, outer: 0.5)
    private let b = segment("b", from: .pi, to: .pi * 1.5, depth: 0, inner: 0.22, outer: 0.5)
    private let c = segment("c", from: 0, to: .pi * 2, depth: 1, inner: 0.52, outer: 0.9)

    private var index: SunburstHitTestIndex {
        SunburstHitTestIndex(segments: [a, b, c])
    }

    /// The id hit at `radius` (fraction of the chart radius) and `clockFraction` of a turn clockwise
    /// from 12 o'clock, on a 200×200 chart.
    private func hit(radius: Double, turn clockFraction: Double, in index: SunburstHitTestIndex? = nil) -> String? {
        let angle = clockFraction * .pi * 2
        let x = 100 + sin(angle) * radius * 100
        let y = 100 - cos(angle) * radius * 100
        return (index ?? self.index).segment(atX: x, y: y, width: 200, height: 200)?.id
    }

    @Test func anglesRunClockwiseFromTwelveOClock() {
        #expect(hit(radius: 0.3, turn: 0.01) == "a")
        #expect(hit(radius: 0.3, turn: 0.25) == "a")
        #expect(hit(radius: 0.3, turn: 0.55) == "b")
        #expect(hit(radius: 0.3, turn: 0.7) == "b")
    }

    @Test func angularGapsAndOutOfBandRadiiMiss() {
        // 10:30 sits in ring 0's empty quarter; atan2 wraps it past zero first.
        #expect(hit(radius: 0.3, turn: 0.875) == nil)
        #expect(hit(radius: 0.1, turn: 0.25) == nil)
        #expect(hit(radius: 0.95, turn: 0.25) == nil)
    }

    @Test func outerRingsAreHitAllTheWayRound() {
        for step in 0..<8 {
            #expect(hit(radius: 0.7, turn: Double(step) / 8 + 0.01) == "c")
        }
    }

    @Test func ringGapBelongsToTheInnerArc() {
        // Past a's drawn edge but inside the cosmetic gap: still a.
        #expect(hit(radius: 0.5 + SunburstLayout.ringGap * 0.6, turn: 0.25) == "a")
        // c's band likewise extends one gap beyond its drawn edge.
        #expect(hit(radius: 0.9 + SunburstLayout.ringGap * 0.6, turn: 0.25) == "c")
        #expect(hit(radius: 0.9 + SunburstLayout.ringGap * 2, turn: 0.25) == nil)
    }

    @Test func inputOrderDoesNotMatter() {
        let shuffled = SunburstHitTestIndex(segments: [c, b, a])
        #expect(hit(radius: 0.3, turn: 0.25, in: shuffled) == "a")
        #expect(hit(radius: 0.3, turn: 0.6, in: shuffled) == "b")
        #expect(hit(radius: 0.7, turn: 0.6, in: shuffled) == "c")
    }

    @Test func emptyIndexOrDegenerateFrameFindsNothing() {
        #expect(SunburstHitTestIndex(segments: []).segment(atX: 100, y: 70, width: 200, height: 200) == nil)
        #expect(index.segment(atX: 0, y: 0, width: 0, height: 200) == nil)
        #expect(index.segment(atX: 0, y: 0, width: 200, height: -1) == nil)
    }

    @Test func nonSquareFramesUseTheShorterSideAsRadius() {
        // 400×200: center (200, 100), radius 100. 30pt above the center is ring 0.
        #expect(index.segment(atX: 200, y: 70, width: 400, height: 200)?.id == "a")
        // 70pt right of center is ring 1 even though the frame is wider.
        #expect(index.segment(atX: 270, y: 100, width: 400, height: 200)?.id == "c")
        #expect(index.segment(atX: 395, y: 100, width: 400, height: 200) == nil)
    }

    @Test func staticHitTesterMatchesTheIndex() {
        #expect(SunburstHitTester.segment(atX: 130, y: 100, width: 200, height: 200, segments: [a, b, c])?.id == "a")
        #expect(SunburstHitTester.segment(atX: 100, y: 100, width: 200, height: 200, segments: [a, b, c]) == nil)
    }

    @Test func cgPointOverloadsForwardToTheDoubleAPI() {
        let size = CGSize(width: 200, height: 200)
        #expect(index.segment(at: CGPoint(x: 130, y: 100), in: size)?.id == "a")
        #expect(SunburstHitTester.segment(at: CGPoint(x: 100, y: 170), in: size, segments: [a, b, c])?.id == "c")
        #expect(SunburstCenterHitTester.contains(point: CGPoint(x: 100, y: 100), in: size))
        #expect(!SunburstCenterHitTester.contains(point: CGPoint(x: 100, y: 70), in: size))
    }

    @Test func centerHoleMatchesTheLayoutsCenterRadius() {
        let inside = 100 * (SunburstLayout.centerRadius - 0.01)
        let outside = 100 * (SunburstLayout.centerRadius + 0.01)
        #expect(SunburstCenterHitTester.contains(atX: 100, y: 100, width: 200, height: 200))
        #expect(SunburstCenterHitTester.contains(atX: 100 + inside, y: 100, width: 200, height: 200))
        #expect(!SunburstCenterHitTester.contains(atX: 100 + outside, y: 100, width: 200, height: 200))
        #expect(SunburstCenterHitTester.contains(atX: 100 + outside, y: 100, width: 200, height: 200, radius: 0.5))
    }

    @Test func centerHoleIsEmptyForDegenerateInput() {
        #expect(!SunburstCenterHitTester.contains(atX: 0, y: 0, width: 0, height: 0))
        #expect(!SunburstCenterHitTester.contains(atX: 100, y: 100, width: 200, height: 200, radius: 0))
        #expect(!SunburstCenterHitTester.contains(atX: 100, y: 100, width: 200, height: 200, radius: -1))
    }

    @Test func layoutRoundtripsThroughTheHitTester() throws {
        let segments = [
            segment("left", from: 0, to: 2, depth: 0, inner: 0.22, outer: 0.45),
            segment("right", from: 2, to: .pi * 2, depth: 0, inner: 0.22, outer: 0.45),
        ]
        let index = SunburstHitTestIndex(segments: segments)
        for segment in segments {
            let mid = (segment.startAngle + segment.endAngle) / 2 / (.pi * 2)
            let radius = (segment.innerRadius + segment.outerRadius) / 2
            #expect(hit(radius: radius, turn: mid, in: index) == segment.id)
        }
    }
}

@Suite struct SunburstZoomGeometryTests {
    private let metrics = SunburstRingMetrics(depthLimit: 4)

    private func ring(_ id: String, _ start: Double, _ end: Double, depth: Int) -> SunburstSegment {
        segment(
            id, from: start, to: end, depth: depth,
            inner: metrics.innerRadius(depth: depth),
            outer: metrics.drawnOuterRadius(depth: depth)
        )
    }

    private var focus: SunburstSegment { ring("focus", .pi / 2, .pi, depth: 0) }
    private var child: SunburstSegment { ring("child", .pi / 2, .pi * 0.75, depth: 1) }
    private var sibling: SunburstSegment { ring("sibling", 0, .pi / 2, depth: 0) }

    private func approx(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    @Test func focusOpensIntoTheCenterDisk() {
        let arc = SunburstZoomGeometry.zoomedArc(for: focus, focus: focus, metrics: metrics)
        #expect(arc == SunburstZoomArc(startRadians: 0, endRadians: .pi * 2, innerRadius: 0, outerRadius: SunburstLayout.centerRadius))
    }

    @Test func descendantsRemapProportionallyAndMoveInOneRing() {
        let arc = SunburstZoomGeometry.zoomedArc(for: child, focus: focus, metrics: metrics)
        #expect(approx(arc.startRadians, 0))
        #expect(approx(arc.endRadians, .pi))
        #expect(approx(arc.innerRadius, metrics.innerRadius(depth: 0)))
        #expect(approx(arc.outerRadius, metrics.drawnOuterRadius(depth: 0)))
        #expect(arc.isDrawable)
    }

    @Test func arcsOutsideTheFocusWedgeCollapse() {
        let arc = SunburstZoomGeometry.zoomedArc(for: sibling, focus: focus, metrics: metrics)
        #expect(arc.startRadians == 0 && arc.endRadians == 0)
        #expect(!arc.isDrawable)
    }

    @Test func ancestorsSinkBelowTheCenterWithoutGoingNegative() {
        let deepFocus = ring("deep", .pi / 2, .pi, depth: 1)
        let ancestor = ring("ancestor", 0, .pi, depth: 0)
        let arc = SunburstZoomGeometry.zoomedArc(for: ancestor, focus: deepFocus, metrics: metrics)
        #expect(approx(arc.startRadians, 0) && approx(arc.endRadians, .pi * 2))
        #expect(approx(arc.innerRadius, max(0, metrics.innerRadius(depth: -2))))
        #expect(approx(arc.outerRadius, max(0, metrics.drawnOuterRadius(depth: -2))))
        #expect(arc.innerRadius >= 0 && arc.outerRadius < SunburstLayout.centerRadius)
    }

    @Test func zeroWidthFocusStaysFinite() {
        let sliver = ring("sliver", 1, 1, depth: 0)
        let arc = SunburstZoomGeometry.zoomedArc(for: child, focus: sliver, metrics: metrics)
        #expect(arc.startRadians.isFinite && arc.endRadians.isFinite)
        #expect(arc.startRadians >= 0 && arc.endRadians <= .pi * 2)
    }

    @Test func progressEndpointsAreIdentityAndZoomed() {
        for segment in [focus, child, sibling] {
            let identity = SunburstZoomGeometry.identityArc(for: segment)
            #expect(identity.startRadians == segment.startAngle && identity.outerRadius == segment.outerRadius)
            #expect(SunburstZoomGeometry.arc(for: segment, focus: focus, progress: 0, metrics: metrics) == identity)
            #expect(SunburstZoomGeometry.arc(for: segment, focus: focus, progress: -1, metrics: metrics) == identity)
            #expect(SunburstZoomGeometry.arc(for: segment, focus: focus, progress: 1, metrics: metrics)
                == SunburstZoomGeometry.zoomedArc(for: segment, focus: focus, metrics: metrics))
        }
    }

    @Test func focusMidwayIsHalfwayBetweenIdentityAndZoomed() {
        // easeInOut(0.5) == 0.5, so the focus sits exactly halfway at half progress.
        let mid = SunburstZoomGeometry.arc(for: focus, focus: focus, progress: 0.5, metrics: metrics)
        #expect(approx(mid.startRadians, .pi / 4))
        #expect(approx(mid.endRadians, .pi * 1.5))
        #expect(approx(mid.innerRadius, focus.innerRadius / 2))
    }

    @Test func staggeredTimingPerRole() {
        // Focus: plain ease. Descendants: held through the start delay. Shell: done by the collapse fraction.
        #expect(approx(SunburstZoomGeometry.timedProgress(for: focus, focus: focus, rawProgress: 0.25), 0.0625))
        #expect(SunburstZoomGeometry.timedProgress(for: child, focus: focus, rawProgress: SunburstZoomGeometry.descendantStartFraction) == 0)
        #expect(SunburstZoomGeometry.timedProgress(for: child, focus: focus, rawProgress: 0.5)
            < SunburstZoomGeometry.timedProgress(for: focus, focus: focus, rawProgress: 0.5))
        #expect(SunburstZoomGeometry.timedProgress(for: sibling, focus: focus, rawProgress: SunburstZoomGeometry.collapseFinishFraction) == 1)
        #expect(SunburstZoomGeometry.timedProgress(for: sibling, focus: focus, rawProgress: 5) == 1)
        #expect(SunburstZoomGeometry.timedProgress(for: focus, focus: focus, rawProgress: -5) == 0)
    }

    @Test func deepSegmentUnderASiblingCollapsesWithTheShell() {
        let nephew = ring("nephew", 0, .pi / 4, depth: 1)
        let raw = SunburstZoomGeometry.collapseFinishFraction
        #expect(SunburstZoomGeometry.timedProgress(for: nephew, focus: focus, rawProgress: raw) == 1)
        #expect(SunburstZoomGeometry.opacity(for: nephew, focus: focus, rawProgress: raw) == 0)
    }

    @Test func opacityFadesShellAndFocusButNeverDescendants() {
        for raw in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(SunburstZoomGeometry.opacity(for: child, focus: focus, rawProgress: raw) == 1)
        }
        #expect(SunburstZoomGeometry.opacity(for: sibling, focus: focus, rawProgress: 0) == 1)
        #expect(SunburstZoomGeometry.opacity(for: sibling, focus: focus, rawProgress: SunburstZoomGeometry.collapseFinishFraction) == 0)
        #expect(SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 0) == 1)
        #expect(SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 0.5) == 1)
        #expect(SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 1) == 0)
        let fading = SunburstZoomGeometry.opacity(for: focus, focus: focus, rawProgress: 0.6)
        #expect(fading > 0 && fading < 1)
    }

    @Test func effectiveDepthBlendsTowardTheRebandedDepth() {
        #expect(SunburstZoomGeometry.effectiveDepth(for: child, focus: focus, progress: 0) == 1)
        #expect(SunburstZoomGeometry.effectiveDepth(for: child, focus: focus, progress: 1) == 0)
        let midway = SunburstZoomGeometry.effectiveDepth(for: child, focus: focus, progress: 0.6)
        #expect(midway > 0 && midway < 1)
        // The focus heads to depth -1, clamped at 0.
        #expect(SunburstZoomGeometry.effectiveDepth(for: focus, focus: focus, progress: 1) == 0)
    }

    @Test func easeInOutIsClampedSymmetricAndMonotonic() {
        #expect(SunburstZoomGeometry.easeInOut(0) == 0)
        #expect(SunburstZoomGeometry.easeInOut(1) == 1)
        #expect(SunburstZoomGeometry.easeInOut(0.5) == 0.5)
        #expect(SunburstZoomGeometry.easeInOut(-2) == 0)
        #expect(SunburstZoomGeometry.easeInOut(3) == 1)
        var previous = 0.0
        for step in 1...20 {
            let t = Double(step) / 20
            let value = SunburstZoomGeometry.easeInOut(t)
            #expect(value >= previous)
            #expect(approx(value + SunburstZoomGeometry.easeInOut(1 - t), 1))
            previous = value
        }
    }

    @Test func drawableNeedsBothAngularAndRadialExtent() {
        #expect(SunburstZoomArc(startRadians: 0, endRadians: 0.01, innerRadius: 0.3, outerRadius: 0.4).isDrawable)
        #expect(!SunburstZoomArc(startRadians: 0, endRadians: 0.0003, innerRadius: 0.3, outerRadius: 0.4).isDrawable)
        #expect(!SunburstZoomArc(startRadians: 0, endRadians: 1, innerRadius: 0.3, outerRadius: 0.3003).isDrawable)
    }
}
