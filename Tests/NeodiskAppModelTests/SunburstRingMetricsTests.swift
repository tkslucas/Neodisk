// Tapered ring radii: deeper rings are thinner, floored so they stay clickable, and fill the same outer radius.

import SunburstCore
import Testing
@testable import NeodiskAppModel

@Suite struct SunburstRingMetricsTests {
    private let available = SunburstRingMetrics.outerRadius - SunburstLayout.centerRadius

    @Test func ringsFillExactlyFromCenterToOuterRadius() {
        for depthLimit in 1...12 {
            let metrics = SunburstRingMetrics(depthLimit: depthLimit)
            #expect(abs(metrics.innerRadius(depth: 0) - SunburstLayout.centerRadius) < 1e-12)

            let total = (0..<depthLimit).reduce(0.0) { $0 + metrics.thickness(depth: $1) }
            #expect(abs(total - available) < 1e-9)

            // The outermost band's edge lands exactly on the outer radius; the
            // drawn arc sits one ring gap short of it.
            let last = depthLimit - 1
            #expect(abs((metrics.drawnOuterRadius(depth: last) + SunburstLayout.ringGap) - SunburstRingMetrics.outerRadius) < 1e-9)
        }
    }

    @Test func thicknessIsMonotonicallyNonIncreasing() {
        let metrics = SunburstRingMetrics(depthLimit: 8)
        for depth in 1..<8 {
            // Each ring is no thicker than the one inside it — the taper only
            // ever thins outward.
            #expect(metrics.thickness(depth: depth) <= metrics.thickness(depth: depth - 1) + 1e-12)
        }
    }

    @Test func onlyTheOutermostTwoBodyRingsTaper() {
        let metrics = SunburstRingMetrics(depthLimit: 6)
        // Every ring inside the taper shares one full thickness…
        let full = metrics.thickness(depth: 0)
        for depth in 1...3 {
            #expect(abs(metrics.thickness(depth: depth) - full) < 1e-12)
        }
        // …then the last two step down: one smaller, the next smaller again,
        // at their published ratios.
        #expect(abs(metrics.thickness(depth: 4) - full * SunburstRingMetrics.penultimateRingRatio) < 1e-12)
        #expect(abs(metrics.thickness(depth: 5) - full * SunburstRingMetrics.lastRingRatio) < 1e-12)
    }

    @Test func layersPastTheBodyAreFixedThinSlivers() {
        // The pane's real configuration: a 6-ring body plus 2 thin detail rings at the published thickness.
        let metrics = SunburstRingMetrics(depthLimit: 8)
        let full = metrics.thickness(depth: 0)
        for depth in 1...3 {
            #expect(abs(metrics.thickness(depth: depth) - full) < 1e-12)
        }
        #expect(abs(metrics.thickness(depth: 4) - full * SunburstRingMetrics.penultimateRingRatio) < 1e-12)
        #expect(abs(metrics.thickness(depth: 5) - full * SunburstRingMetrics.lastRingRatio) < 1e-12)
        #expect(abs(metrics.thickness(depth: 6) - SunburstRingMetrics.fixedThinThickness) < 1e-12)
        #expect(abs(metrics.thickness(depth: 7) - SunburstRingMetrics.fixedThinThickness) < 1e-12)
        // The slivers are the thinnest rings — the taper never inverts.
        #expect(metrics.thickness(depth: 6) < metrics.thickness(depth: 5))
    }

    @Test func twoOrFewerRingsStayUniform() {
        // With nothing inside the taper to read against, the split is equal.
        let metrics = SunburstRingMetrics(depthLimit: 2)
        #expect(abs(metrics.thickness(depth: 0) - metrics.thickness(depth: 1)) < 1e-12)
    }

    @Test func floorKeepsDeepRingsClickable() {
        // Tapered rings dip under the floor while it still fits: all stay at least the floor, total never overruns.
        let metrics = SunburstRingMetrics(depthLimit: 20)
        var total = 0.0
        for depth in 0..<20 {
            let thickness = metrics.thickness(depth: depth)
            #expect(thickness >= SunburstRingMetrics.minThicknessFraction - 1e-9)
            total += thickness
        }
        #expect(abs(total - available) < 1e-9)
    }

    @Test func infeasibleFloorFallsBackToEqualSplitThatStillFits() {
        // Even all-floor would overrun: the floor yields to an equal split, since the total wins over clickability.
        let depthLimit = 40
        let metrics = SunburstRingMetrics(depthLimit: depthLimit)
        #expect(Double(depthLimit) * SunburstRingMetrics.minThicknessFraction > available)

        let expected = available / Double(depthLimit)
        var total = 0.0
        for depth in 0..<depthLimit {
            #expect(abs(metrics.thickness(depth: depth) - expected) < 1e-12)
            total += metrics.thickness(depth: depth)
        }
        #expect(abs(total - available) < 1e-9)
    }

    @Test func bandsAreContiguousAcrossTheRingGap() {
        let metrics = SunburstRingMetrics(depthLimit: 6)
        for depth in 0..<5 {
            // The drawn arc ends one ring gap short of the next ring's inner
            // edge — no overlap, and the gap is exactly the cosmetic seam.
            let drawnOuter = metrics.drawnOuterRadius(depth: depth)
            let nextInner = metrics.innerRadius(depth: depth + 1)
            #expect(abs((drawnOuter + SunburstLayout.ringGap) - nextInner) < 1e-12)
        }
    }

    @Test func boundaryRadiusExtrapolatesBelowCenterForCollapsingShell() {
        // Negative indices (an ancestor shell collapsing through the center) extrapolate so the morph stays smooth.
        let metrics = SunburstRingMetrics(depthLimit: 6)
        #expect(metrics.boundaryRadius(ringIndex: 0) == SunburstLayout.centerRadius)
        #expect(metrics.boundaryRadius(ringIndex: -1) < SunburstLayout.centerRadius)
        #expect(metrics.boundaryRadius(ringIndex: -2) < metrics.boundaryRadius(ringIndex: -1))
    }
}
