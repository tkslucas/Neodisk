// The drill transition over fitted charts: the drilled folder's contents move the whole way, in and out, and
// land exactly on the chart that replaces the animation.

import Foundation
import NeodiskKit
import SunburstCore
import Testing
@testable import NeodiskAppModel

@Suite struct SunburstDrillTransitionTests {
    /// /Applications in miniature: nine big apps fill one ring; Utilities (6%) holds small apps and a folder,
    /// too little to earn the root chart a second ring, enough for two rings once drilled into.
    private let store: FileTreeStore = {
        let kitFiles = (0..<2).map { makeTestFileNode(id: "/apps/Utilities/Kit/f\($0)", name: "f\($0)", size: 10) }
        let kit = makeTestDirectoryNode(id: "/apps/Utilities/Kit", name: "Kit", children: kitFiles)
        let utilityApps = (0..<4).map { makeTestFileNode(id: "/apps/Utilities/u\($0)", name: "u\($0)", size: 10) }
        let utilities = makeTestDirectoryNode(id: "/apps/Utilities", name: "Utilities", children: utilityApps + [kit])
        let apps = (0..<9).map { makeTestFileNode(id: "/apps/a\($0)", name: "a\($0)", size: 100) }
        let root = makeTestDirectoryNode(id: "/apps", name: "apps", children: apps + [utilities])
        return FileTreeStore(root: root, childrenByID: [
            "/apps": apps + [utilities],
            "/apps/Utilities": utilityApps + [kit],
            "/apps/Utilities/Kit": kitFiles,
        ])
    }()

    private let depthLimit = 8

    private func layout(_ rootID: String) throws -> SunburstChartLayout {
        try SunburstLayout.layout(in: store, rootID: rootID, depthLimit: depthLimit, cancellationCheck: {})
    }

    @Test func theFittedChartIsTheFullLayoutsShallowRings() throws {
        let fitted = try layout("/apps")
        #expect(fitted.ringCount == 1)
        let alone = try SunburstLayout.segments(in: store, rootID: "/apps", depthLimit: 1, cancellationCheck: {})
        #expect(fitted.segments == alone)
        // The rings past the fit wait at the rim, unseen.
        #expect(fitted.deepSegments.map(\.nodeID).contains("/apps/Utilities/Kit/f0"))
        for segment in fitted.deepSegments {
            #expect(segment.depth >= 1)
            #expect(!SunburstZoomGeometry.identityArc(for: segment).isDrawable)
        }
    }

    @Test func aDrillInPredictsTheDrilledChartsRings() throws {
        let outgoing = try layout("/apps")
        let focus = try #require(outgoing.segments.first { $0.nodeID == "/apps/Utilities" })
        let predicted = SunburstLayout.predictedRingCount(
            drillingInto: focus, in: outgoing.transitionSegments, depthLimit: depthLimit
        )
        #expect(predicted == 2)
        #expect(try layout("/apps/Utilities").ringCount == 2)
    }

    @Test func drillingInShowsTheFolderTheWholeWayAndLandsOnItsChart() throws {
        let outgoing = try layout("/apps")
        let incoming = try layout("/apps/Utilities")
        let focus = try #require(outgoing.segments.first { $0.nodeID == "/apps/Utilities" })
        var state = SunburstZoomTransitionState.zoomIn(layout: outgoing, focus: focus, depthLimit: depthLimit)
        state.incomingLayoutLanded(incoming, at: state.startDate)
        #expect(state.replacedRings == nil)
        let target = SunburstZoomPresentation(state: state, now: state.startDate).target

        expectNoBlankFrame(state.animatedSegments, focus: focus, target: target, chart: incoming.segments)
        expectLands(state.animatedSegments, focus: focus, target: target, on: incoming.segments)
    }

    @Test func drillingOutShowsTheFolderTheWholeWayAndStartsOnItsChart() throws {
        let outgoing = try layout("/apps/Utilities")
        let parent = try layout("/apps")
        var state = SunburstZoomTransitionState.zoomOut(previous: outgoing, previousRootID: "/apps/Utilities")
        let focus = try #require(parent.segments.first { $0.nodeID == "/apps/Utilities" })
        state.parentLayoutLanded(parent, focus: focus, at: state.startDate)
        let target = SunburstZoomPresentation(state: state, now: state.startDate).target

        // Every ring of the outgoing chart is carried, so none is left to fade as an orphan.
        #expect(outgoing.segments.allSatisfy { $0.depth <= state.handoffFadeDepthThreshold })
        expectNoBlankFrame(state.animatedSegments, focus: focus, target: target, chart: outgoing.segments)
        expectLands(state.animatedSegments, focus: focus, target: target, on: outgoing.segments)
        // And it ends on the parent chart as drawn: deep rings back at the rim.
        for segment in state.animatedSegments {
            let arc = SunburstZoomGeometry.arc(for: segment, focus: focus, progress: 0, target: target)
            #expect(arc == SunburstZoomGeometry.identityArc(for: segment))
        }
    }

    @Test func aCorrectedPredictionBendsTheRemapBeforeTheHandoff() throws {
        let outgoing = try layout("/apps")
        let focus = try #require(outgoing.segments.first { $0.nodeID == "/apps/Utilities" })
        // A chart that pooled Utilities' contents would predict one ring.
        let pooled = SunburstChartLayout(segments: outgoing.segments)
        var state = SunburstZoomTransitionState.zoomIn(layout: pooled, focus: focus, depthLimit: depthLimit)
        #expect(state.zoomedInRings.depthLimit == 1)

        let landed = state.startDate.addingTimeInterval(0.3)
        state.incomingLayoutLanded(try layout("/apps/Utilities"), at: landed)
        #expect(state.replacedRings?.depthLimit == 1)
        #expect(state.zoomedInRings.depthLimit == 2)

        let one = SunburstRingMetrics(depthLimit: 1)
        let two = SunburstRingMetrics(depthLimit: 2)
        let atLanding = SunburstZoomPresentation(state: state, now: landed).target
        #expect(abs(atLanding.drawnOuterRadius(depth: 0) - one.drawnOuterRadius(depth: 0)) < 1e-9)

        // The handoff waits for the bend, which ends exactly on the landed rings.
        let bent = landed.addingTimeInterval(SunburstZoomTransitionState.retargetDuration)
        let beforeHandoff = SunburstZoomPresentation(state: state, now: bent.addingTimeInterval(-0.01))
        #expect(beforeHandoff.phase == .zooming(progress: 1))
        let handoff = SunburstZoomPresentation(state: state, now: bent)
        #expect(handoff.phase == .revealingIncoming(alpha: 0))
        #expect(abs(handoff.target.drawnOuterRadius(depth: 0) - two.drawnOuterRadius(depth: 0)) < 1e-9)
    }

    @Test func ringsPastTheTargetRestAtTheRim() {
        let target = SunburstZoomTarget(SunburstRingMetrics(depthLimit: 2))
        #expect(target.innerRadius(depth: 2) == SunburstRingMetrics.outerRadius)
        #expect(target.drawnOuterRadius(depth: 5) == SunburstRingMetrics.outerRadius)
        #expect(target.innerRadius(depth: -3) == 0)
    }

    // MARK: - Frames

    /// Drawn area (in chart-radius² units, weighted by opacity) of one remapped frame.
    private func drawnArea(
        _ segments: [SunburstSegment], focus: SunburstSegment, target: SunburstZoomTarget, progress: Double
    ) -> Double {
        segments.reduce(0) { area, segment in
            let opacity = SunburstZoomGeometry.opacity(for: segment, focus: focus, rawProgress: progress)
            let arc = SunburstZoomGeometry.arc(for: segment, focus: focus, progress: progress, target: target)
            guard opacity > 0.001, arc.isDrawable else { return area }
            let sweep = arc.endRadians - arc.startRadians
            return area + opacity * sweep * (arc.outerRadius * arc.outerRadius - arc.innerRadius * arc.innerRadius) / 2
        }
    }

    /// The bug this guards: a fitted chart carried none of the drilled folder's rings, so mid-zoom the frame
    /// emptied out before the new chart faded in.
    private func expectNoBlankFrame(
        _ segments: [SunburstSegment], focus: SunburstSegment, target: SunburstZoomTarget,
        chart: [SunburstSegment]
    ) {
        let chartArea = chart.reduce(0.0) { area, segment in
            area + (segment.endAngle - segment.startAngle)
                * (segment.outerRadius * segment.outerRadius - segment.innerRadius * segment.innerRadius) / 2
        }
        for step in 0...40 {
            let progress = Double(step) / 40
            let area = drawnArea(segments, focus: focus, target: target, progress: progress)
            #expect(area > chartArea * 0.2, "progress \(progress): \(area) of \(chartArea)")
        }
    }

    /// No jump at the end: the last frame is the drilled chart, arc for arc.
    private func expectLands(
        _ segments: [SunburstSegment], focus: SunburstSegment, target: SunburstZoomTarget,
        on chart: [SunburstSegment]
    ) {
        let landed = Dictionary(uniqueKeysWithValues: segments.map {
            ($0.id, SunburstZoomGeometry.arc(for: $0, focus: focus, progress: 1, target: target))
        })
        for segment in chart {
            guard let arc = landed[segment.id] else {
                Issue.record("\(segment.id) not carried")
                continue
            }
            let identity = SunburstZoomGeometry.identityArc(for: segment)
            #expect(abs(arc.startRadians - identity.startRadians) < 1e-9, "\(segment.id)")
            #expect(abs(arc.endRadians - identity.endRadians) < 1e-9, "\(segment.id)")
            #expect(abs(arc.innerRadius - identity.innerRadius) < 1e-9, "\(segment.id)")
            #expect(abs(arc.outerRadius - identity.outerRadius) < 1e-9, "\(segment.id)")
        }
    }
}
