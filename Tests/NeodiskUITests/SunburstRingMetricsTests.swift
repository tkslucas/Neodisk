//
//  SunburstRingMetricsTests.swift
//  Neodisk
//
//  The tapered ring radii: the single source of truth for how deep the
//  sunburst's rings sit. DaisyDisk-style — deeper rings are thinner bands,
//  floored so they stay clickable, normalized to fill the same outer radius
//  no matter the ring count.
//

import SunburstCore
import Testing

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
        // The pane's actual configuration: a 6-ring body plus 2 fixed thin
        // detail rings. The body keeps its full/taper composition over the
        // span the slivers leave behind; the slivers sit at exactly the
        // published thickness.
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
        // Enough rings that the tapered outer rings dip under the floor while
        // the floor still fits: every ring stays at least the floor thick, and
        // the total never overruns.
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
        // So many rings that even an all-floor stack would overrun the span:
        // the floor is abandoned for an equal split, but the total still fills
        // exactly (correctness of the total wins over the clickability floor).
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
        // The zoom remap asks for negative ring indices (an ancestor shell
        // collapsing through the center). They extrapolate monotonically past
        // the center hole so the morph stays continuous.
        let metrics = SunburstRingMetrics(depthLimit: 6)
        #expect(metrics.boundaryRadius(ringIndex: 0) == SunburstLayout.centerRadius)
        #expect(metrics.boundaryRadius(ringIndex: -1) < SunburstLayout.centerRadius)
        #expect(metrics.boundaryRadius(ringIndex: -2) < metrics.boundaryRadius(ringIndex: -1))
    }
}
