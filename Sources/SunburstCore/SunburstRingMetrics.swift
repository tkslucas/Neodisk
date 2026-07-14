//
//  SunburstRingMetrics.swift
//  SunburstCore
//
//  The single source of truth for sunburst ring radii. DaisyDisk renders the
//  deepest levels as THINNER arcs so the outer detail takes less radial space
//  and the chart reads better; this computes that taper once and everything —
//  the layout, the drill/zoom remap, and (transitively, via the segment radii
//  it stamps) hit-testing — bands its rings through here, so the drawn arcs
//  and the hovered arcs can never disagree.
//
//  Pure stdlib: no Foundation, so it stays Embedded-Swift-compatible for the
//  wasm build alongside the rest of SunburstCore.
//

/// Maps a ring depth to its radial band. The body rings share one full
/// thickness except the body's outermost two, which step down (2/3, then 4/9
/// of a full ring); depth layers past the body render as fixed thin slivers
/// at the edge. Everything is floored so deep arcs stay clickable, and the
/// whole stack is normalized to fill exactly the same outer radius regardless
/// of how many rings there are.
public struct SunburstRingMetrics: Sendable, Equatable {
    /// The ring budget the body composition is tuned for: within it, only the
    /// outermost rings thin and everything inside them keeps one full, equal
    /// thickness (owner-tuned 2026-07-13: an all-depths geometric taper read
    /// as goofy).
    public static let bodyRingCount = 6
    /// The body's next-to-last ring's fraction of a full ring, and its last
    /// ring's — one step smaller, then one smaller again.
    public static let penultimateRingRatio: Double = 2.0 / 3.0
    public static let lastRingRatio: Double = 4.0 / 9.0
    /// Depth layers past the body render as fixed thin detail rings at the
    /// very edge (DaisyDisk's outer slivers), at most this many.
    public static let fixedThinRingCount = 2
    /// Each fixed thin ring's band as a fraction of the chart radius. The
    /// cosmetic `ringGap` comes out of the band, so the drawn sliver is
    /// `0.038 - 0.015 = 0.023` — thin, but still hoverable.
    public static let fixedThinThickness: Double = 0.038
    /// A ring's band never gets thinner than this fraction of the chart
    /// radius, so deep arcs stay clickable. At a typical ~250pt chart radius
    /// that is ~9pt. When the floor binds (many rings), the radius it claims
    /// is taken from the still-tapering rings by water-filling — never added
    /// to the total, which always fills exactly `centerRadius … outerRadius`.
    public static let minThicknessFraction: Double = 0.036
    /// The chart's outer edge as a fraction of the chart radius — a hair shy
    /// of the full radius, matching the pre-taper layout's outer bound.
    public static let outerRadius: Double = 0.98

    public let depthLimit: Int
    /// Ring boundary radii: `boundaries[d]` is the inner edge of ring `d`,
    /// `boundaries[d + 1]` its outer band edge (the drawn arc sits `ringGap`
    /// short of it). `count == depthLimit + 1`, spanning the center hole edge
    /// to `outerRadius`.
    private let boundaries: [Double]
    /// Edge-ring thicknesses, used to extrapolate boundary radii for the
    /// out-of-range ring indices the zoom remap asks about (a collapsing
    /// ancestor shell sits at negative relative depth).
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

    /// The drawn outer radius of ring `depth`: the band's outer edge less the
    /// cosmetic `ringGap`. Hit-testing glues the gap back on (see
    /// `SunburstHitTestIndex`), so the gap is a seam, never a dead zone.
    public func drawnOuterRadius(depth: Int) -> Double {
        boundaryRadius(ringIndex: depth + 1) - SunburstLayout.ringGap
    }

    /// The full band thickness of ring `depth` (gap included). Exposed for the
    /// taper's invariants — monotonic non-increasing, floored, summing to the
    /// available span.
    public func thickness(depth: Int) -> Double {
        boundaryRadius(ringIndex: depth + 1) - boundaryRadius(ringIndex: depth)
    }

    /// The radius at a ring boundary. Inside `0...depthLimit` it reads the
    /// precomputed table; outside it (the zoom remap's re-banded descendants
    /// and collapsing shell can land at negative or beyond-limit indices) it
    /// extrapolates linearly by the nearest edge ring's thickness so the
    /// morph stays continuous instead of snapping.
    public func boundaryRadius(ringIndex: Int) -> Double {
        if ringIndex < 0 {
            return boundaries[0] + (Double(ringIndex) * firstThickness)
        }
        if ringIndex > depthLimit {
            return boundaries[depthLimit] + (Double(ringIndex - depthLimit) * lastThickness)
        }
        return boundaries[ringIndex]
    }

    /// Ring thicknesses, normalized to fill exactly `available`: the body
    /// rings split the span left over by the fixed thin edge rings, which
    /// claim `fixedThinThickness` apiece. Degenerate spans (where the special
    /// casing would leave a body ring thinner than the thin edge, inverting
    /// the taper) fall back to an equal split.
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

    /// The body rings' thicknesses, floored and normalized to fill exactly
    /// `available`. All rings weigh 1 except the outermost two, which get the
    /// taper ratios; the weights are scaled to the available span. Rings that
    /// would fall below the floor are water-filled: pinned at the floor, with
    /// the remaining span redivided among the rest by their weights, iterating
    /// until stable — so the floor is honored without ever overrunning the
    /// total.
    private static func bodyThicknesses(count: Int, available: Double) -> [Double] {
        guard count > 0, available > 0 else { return [] }

        let floor = Self.minThicknessFraction
        // Floor infeasible (so many rings that even all-floor overruns the
        // span): fall back to an equal split so the total still fits — the
        // best the geometry can do when there is no room to taper.
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
