// Polar remap for the drill transition: the clicked arc opens to the full circle, its band becomes the
// center disk, descendants shift up one ring, and everything outside collapses.

/// Same normalized coordinates as SunburstSegment.
public struct SunburstZoomArc: Equatable {
    public var startRadians: Double
    public var endRadians: Double
    public var innerRadius: Double
    public var outerRadius: Double

    public init(
        startRadians: Double,
        endRadians: Double,
        innerRadius: Double,
        outerRadius: Double
    ) {
        self.startRadians = startRadians
        self.endRadians = endRadians
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
    }

    /// Collapsed arcs (outside the focus wedge, or radially swallowed by the
    /// center) are skipped instead of stroked as hairline slivers.
    public var isDrawable: Bool {
        endRadians - startRadians > 0.0004 && outerRadius - innerRadius > 0.0004
    }
}

public enum SunburstZoomGeometry {
    /// The outgoing shell collapses fast while descendants start a beat later; the focus bridges the two.
    public static let collapseFinishFraction = 0.55
    public static let descendantStartFraction = 0.12
    /// Gone well before its collapse completes so ancestor rings never read as a circle closing on the center.
    public static let shellFadeOutFraction = 0.7
    /// Fades before its band seals into the center disk, for the same reason as the shell.
    public static let focusFadeStartFraction = 0.55
    public static let focusFadeEndFraction = 0.9

    public nonisolated static func zoomedArc(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        metrics: SunburstRingMetrics
    ) -> SunburstZoomArc {
        zoomedArc(for: segment, focus: focus, target: SunburstZoomTarget(metrics))
    }

    public nonisolated static func zoomedArc(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        target: SunburstZoomTarget
    ) -> SunburstZoomArc {
        if segment.id == focus.id {
            return SunburstZoomArc(
                startRadians: 0,
                endRadians: .pi * 2,
                innerRadius: 0,
                outerRadius: SunburstLayout.centerRadius
            )
        }

        let span = max(focus.endAngle - focus.startAngle, 1e-9)
        func remappedRadians(_ radians: Double) -> Double {
            min(max((radians - focus.startAngle) / span, 0), 1) * .pi * 2
        }

        // Same radii the real re-layout (focus as root) will stamp, so the handoff is an invisible cut.
        // Ancestors land at negative indices, which metrics extrapolates toward the center; rings past the
        // drilled chart's rest at its rim.
        let relativeDepth = segment.depth - focus.depth - 1

        return SunburstZoomArc(
            startRadians: remappedRadians(segment.startAngle),
            endRadians: remappedRadians(segment.endAngle),
            innerRadius: target.innerRadius(depth: relativeDepth),
            outerRadius: target.drawnOuterRadius(depth: relativeDepth)
        )
    }

    public nonisolated static func identityArc(for segment: SunburstSegment) -> SunburstZoomArc {
        SunburstZoomArc(
            startRadians: segment.startAngle,
            endRadians: segment.endAngle,
            innerRadius: segment.innerRadius,
            outerRadius: segment.outerRadius
        )
    }

    /// Progress arrives linear; each segment eases on its own staggered timing (`timedProgress`).
    public nonisolated static func arc(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double,
        metrics: SunburstRingMetrics
    ) -> SunburstZoomArc {
        arc(for: segment, focus: focus, progress: rawProgress, target: SunburstZoomTarget(metrics))
    }

    /// The outgoing chart's arcs start where they're drawn (deep rings at its rim, unseen) and end on `target`.
    public nonisolated static func arc(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double,
        target: SunburstZoomTarget
    ) -> SunburstZoomArc {
        let progress = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        let identity = identityArc(for: segment)
        guard progress > 0 else { return identity }
        let zoomed = zoomedArc(for: segment, focus: focus, target: target)
        guard progress < 1 else { return zoomed }

        return SunburstZoomArc(
            startRadians: lerp(identity.startRadians, zoomed.startRadians, progress),
            endRadians: lerp(identity.endRadians, zoomed.endRadians, progress),
            innerRadius: lerp(identity.innerRadius, zoomed.innerRadius, progress),
            outerRadius: lerp(identity.outerRadius, zoomed.outerRadius, progress)
        )
    }

    /// Blended on the geometry's timing so a ring doesn't pop a shade at the handoff to the real layout.
    public nonisolated static func effectiveDepth(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double
    ) -> Double {
        let progress = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        let target = Double(segment.depth - focus.depth - 1)
        return max(0, lerp(Double(segment.depth), target, progress))
    }

    /// A deeper segment under a sibling collapses with the shell, not with the reveal.
    public nonisolated static func timedProgress(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        rawProgress: Double
    ) -> Double {
        let raw = min(max(rawProgress, 0), 1)
        if segment.id == focus.id {
            return easeInOut(raw)
        }
        if isDescendant(segment, of: focus) {
            return easeInOut((raw - descendantStartFraction) / (1 - descendantStartFraction))
        }

        return easeInOut(raw / collapseFinishFraction)
    }

    public nonisolated static func opacity(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        rawProgress: Double
    ) -> Double {
        if isDescendant(segment, of: focus) {
            return 1
        }

        let timed = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        if segment.id == focus.id {
            let fadeSpan = focusFadeEndFraction - focusFadeStartFraction
            return 1 - min(max((timed - focusFadeStartFraction) / fadeSpan, 0), 1)
        }

        return 1 - min(timed / shellFadeOutFraction, 1)
    }

    private nonisolated static func isDescendant(
        _ segment: SunburstSegment,
        of focus: SunburstSegment
    ) -> Bool {
        segment.depth > focus.depth
            && segment.startAngle >= focus.startAngle - 1e-9
            && segment.endAngle <= focus.endAngle + 1e-9
    }

    public nonisolated static func easeInOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        if clamped < 0.5 {
            return 4 * clamped * clamped * clamped
        }
        let inverted = -2 * clamped + 2
        return 1 - (inverted * inverted * inverted) / 2
    }

    private nonisolated static func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + ((to - from) * t)
    }
}

/// The drilled-in chart's rings, where the remap lands. While a landed layout corrects the ring count a
/// drill-in predicted, a blend of the two, so the motion bends toward the real rings instead of jumping.
public struct SunburstZoomTarget: Sendable, Equatable {
    public var metrics: SunburstRingMetrics
    /// The prediction `metrics` replaces, and how far along (0: all prediction, 1: all `metrics`).
    public var replacing: SunburstRingMetrics?
    public var blend: Double

    public init(_ metrics: SunburstRingMetrics, replacing: SunburstRingMetrics? = nil, blend: Double = 1) {
        self.metrics = metrics
        self.replacing = replacing
        self.blend = min(max(blend, 0), 1)
    }

    /// Clamped to the chart: below 0 for the collapsing shell, at the rim, with no thickness, past the last ring.
    public func innerRadius(depth: Int) -> Double {
        clamped(blended { $0.innerRadius(depth: depth) })
    }

    public func drawnOuterRadius(depth: Int) -> Double {
        clamped(blended { $0.drawnOuterRadius(depth: depth) })
    }

    private func blended(_ radius: (SunburstRingMetrics) -> Double) -> Double {
        let landed = radius(metrics)
        guard let replacing else { return landed }
        let predicted = radius(replacing)
        return predicted + ((landed - predicted) * blend)
    }

    private func clamped(_ radius: Double) -> Double {
        min(max(radius, 0), SunburstRingMetrics.outerRadius)
    }
}
