// Single source of truth for ring radii: layout, zoom remap and hit-testing all band through here, so drawn and
// hovered arcs never disagree. Pure stdlib (no Foundation) for the Embedded Swift wasm build.

/// Body rings share one thickness except the outer two, which step down; deeper layers are fixed thin slivers.
/// Floored so deep arcs stay clickable, and normalized to the same outer radius at any ring count.
public struct SunburstRingMetrics: Sendable, Equatable {
    /// Owner-tuned 2026-07-13: only the outermost rings thin, since an all-depths taper read as goofy.
    public static let bodyRingCount = 6
    /// The body's next-to-last ring's fraction of a full ring, and its last
    /// ring's — one step smaller, then one smaller again.
    public static let penultimateRingRatio: Double = 2.0 / 3.0
    public static let lastRingRatio: Double = 4.0 / 9.0
    /// Depth layers past the body render as fixed thin detail rings at the
    /// very edge (the outer slivers), at most this many.
    public static let fixedThinRingCount = 2
    /// `ringGap` comes out of the band, so the drawn sliver is 0.023: thin, but still hoverable.
    public static let fixedThinThickness: Double = 0.038
    /// About 9pt at a typical chart radius. When it binds, the space is water-filled from the other rings,
    /// never added to the total.
    public static let minThicknessFraction: Double = 0.036
    /// The chart's outer edge as a fraction of the chart radius — a hair shy
    /// of the full radius, matching the pre-taper layout's outer bound.
    public static let outerRadius: Double = 0.98

    public let depthLimit: Int
    /// `boundaries[d]` is ring d's inner edge; `count == depthLimit + 1`.
    private let boundaries: [Double]
    /// For extrapolating out-of-range indices the zoom remap asks about (a collapsing shell sits below 0).
    private let firstThickness: Double
    private let lastThickness: Double

    public init(depthLimit: Int) {
        let limit = max(depthLimit, 1)
        self.depthLimit = limit

        let inner = SunburstLayout.centerRadius
        let available = Self.outerRadius - inner
        let thicknesses = Self.ringThicknesses(count: limit, available: available)

        var bounds: [Double] = [inner]
        bounds.reserveCapacity(limit + 1)
        var cursor = inner
        for thickness in thicknesses {
            cursor += thickness
            bounds.append(cursor)
        }
        // Pin the outer edge exactly, absorbing any floating-point drift the
        // running sum accumulated.
        bounds[limit] = Self.outerRadius

        self.boundaries = bounds
        self.firstThickness = thicknesses.first ?? available
        self.lastThickness = thicknesses.last ?? available
    }

    /// The inner radius of ring `depth` (the band's start).
    public func innerRadius(depth: Int) -> Double {
        boundaryRadius(ringIndex: depth)
    }

    /// Hit-testing glues `ringGap` back on (see `SunburstHitTestIndex`), so the gap is a seam, not a dead zone.
    public func drawnOuterRadius(depth: Int) -> Double {
        boundaryRadius(ringIndex: depth + 1) - SunburstLayout.ringGap
    }

    /// Gap included; exposed for the taper's invariant tests.
    public func thickness(depth: Int) -> Double {
        boundaryRadius(ringIndex: depth + 1) - boundaryRadius(ringIndex: depth)
    }

    /// Out-of-range indices extrapolate by the nearest edge ring's thickness so the zoom morph doesn't snap.
    public func boundaryRadius(ringIndex: Int) -> Double {
        if ringIndex < 0 {
            return boundaries[0] + (Double(ringIndex) * firstThickness)
        }
        if ringIndex > depthLimit {
            return boundaries[depthLimit] + (Double(ringIndex - depthLimit) * lastThickness)
        }
        return boundaries[ringIndex]
    }

    /// Degenerate spans, where a body ring would end up thinner than the thin edge, fall back to an equal split.
    static func ringThicknesses(count: Int, available: Double) -> [Double] {
        guard count > 0, available > 0 else { return [] }

        let thinCount = min(max(count - Self.bodyRingCount, 0), Self.fixedThinRingCount)
        let thin = Self.fixedThinThickness
        let bodyAvailable = available - (Double(thinCount) * thin)
        guard bodyAvailable > 0 else {
            return Array(repeating: available / Double(count), count: count)
        }

        var thicknesses = bodyThicknesses(count: count - thinCount, available: bodyAvailable)
        if let bodyLast = thicknesses.last, bodyLast < thin {
            return Array(repeating: available / Double(count), count: count)
        }
        thicknesses.append(contentsOf: repeatElement(thin, count: thinCount))
        return thicknesses
    }

    /// Rings below the floor are pinned there and the rest redivide the remainder by weight until stable.
    private static func bodyThicknesses(count: Int, available: Double) -> [Double] {
        guard count > 0, available > 0 else { return [] }

        let floor = Self.minThicknessFraction
        // Floor infeasible: an equal split is the best the geometry can do.
        if Double(count) * floor >= available {
            return Array(repeating: available / Double(count), count: count)
        }

        var weights = [Double](repeating: 1, count: count)
        // The taper wants full-thickness rings inside it to read against;
        // with 2 or fewer rings there is no "inside", so stay uniform.
        if count > 2 {
            weights[count - 2] = Self.penultimateRingRatio
            weights[count - 1] = Self.lastRingRatio
        }

        var pinned = [Bool](repeating: false, count: count)
        var thickness = [Double](repeating: 0, count: count)
        while true {
            var pinnedCount = 0
            for depth in 0..<count where pinned[depth] { pinnedCount += 1 }
            let remaining = available - (floor * Double(pinnedCount))

            var weightSum = 0.0
            for depth in 0..<count where !pinned[depth] { weightSum += weights[depth] }
            guard weightSum > 0 else { break }

            var pinnedThisPass = false
            for depth in 0..<count where !pinned[depth] {
                if (weights[depth] / weightSum) * remaining < floor {
                    pinned[depth] = true
                    pinnedThisPass = true
                }
            }

            if !pinnedThisPass {
                for depth in 0..<count where !pinned[depth] {
                    thickness[depth] = (weights[depth] / weightSum) * remaining
                }
                break
            }
        }
        for depth in 0..<count where pinned[depth] { thickness[depth] = floor }
        return thickness
    }
}
