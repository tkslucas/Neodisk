//
//  SunburstZoomGeometry.swift
//  SunburstCore
//
//  The polar remap math for the DaisyDisk-style drill transition: the clicked
//  segment's arc sweeps open to the full circle while its band morphs into the
//  center disk, its descendants shift up one ring per level, and everything
//  outside the arc collapses to zero width. Pure — the SwiftUI Canvas that
//  draws these arcs and the per-frame state machine stay in NeodiskUI.
//

/// A segment's polar geometry mid-transition, in the same normalized
/// coordinates as SunburstSegment (radians clockwise from 12 o'clock, radii
/// as fractions of the chart radius).
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
    /// Staggered per-segment timing over the linear transition progress:
    /// the outgoing shell (ancestors, siblings, anything not under the
    /// focus) collapses fast — done by this fraction — while descendants
    /// start a beat later and glide over the rest of the duration. The
    /// focus itself keeps the plain full-length curve, bridging the two.
    public static let collapseFinishFraction = 0.55
    public static let descendantStartFraction = 0.12
    /// The shell fades out over this much of its own schedule, so it is
    /// gone well before its collapse completes — ancestor rings never read
    /// as a circle closing on the center. (Mirrored on zoom-out: the
    /// parent shell fades in while fanning outward.)
    public static let shellFadeOutFraction = 0.7
    /// The focus stays opaque while its arc sweeps open, then fades over
    /// this window of its schedule — gone before its band seals into a
    /// disk at the center (the same closing-circle read as the shell).
    public static let focusFadeStartFraction = 0.55
    public static let focusFadeEndFraction = 0.9

    /// Where a segment of the focus's layout sits once the chart is fully
    /// zoomed into `focus`: the focus itself becomes the center disk,
    /// descendants shift up `focus.depth + 1` rings with their angles
    /// remapped from the focus arc onto the full circle, ancestors shrink
    /// into the center, and segments outside the arc clamp to zero width.
    public nonisolated static func zoomedArc(
        for segment: SunburstSegment,
        focus: SunburstSegment
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

        // The full ring band width — segments draw their outer edge short of
        // it by the cosmetic ring gap, so add the gap back before re-banding.
        let ringWidth = (focus.outerRadius + SunburstLayout.ringGap) - focus.innerRadius
        let relativeDepth = Double(segment.depth - focus.depth - 1)
        let innerRadius = SunburstLayout.centerRadius + (relativeDepth * ringWidth)
        let outerRadius = innerRadius + ringWidth - SunburstLayout.ringGap

        return SunburstZoomArc(
            startRadians: remappedRadians(segment.startAngle),
            endRadians: remappedRadians(segment.endAngle),
            innerRadius: max(0, innerRadius),
            outerRadius: max(0, outerRadius)
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

    /// Blend between the segment's own geometry (progress 0) and its fully
    /// zoomed geometry (progress 1). Progress arrives linear; each segment
    /// eases on its own staggered timing (see `timedProgress`).
    public nonisolated static func arc(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double
    ) -> SunburstZoomArc {
        let progress = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        let identity = identityArc(for: segment)
        guard progress > 0 else { return identity }
        let zoomed = zoomedArc(for: segment, focus: focus)
        guard progress < 1 else { return zoomed }

        return SunburstZoomArc(
            startRadians: lerp(identity.startRadians, zoomed.startRadians, progress),
            endRadians: lerp(identity.endRadians, zoomed.endRadians, progress),
            innerRadius: lerp(identity.innerRadius, zoomed.innerRadius, progress),
            outerRadius: lerp(identity.outerRadius, zoomed.outerRadius, progress)
        )
    }

    /// Fractional ring depth for the depth-faded fill, blended on the same
    /// staggered timing as the geometry so a ring doesn't pop a shade at
    /// the handoff to the real layout (where the same node is one depth
    /// shallower).
    public nonisolated static func effectiveDepth(
        for segment: SunburstSegment,
        focus: SunburstSegment,
        progress rawProgress: Double
    ) -> Double {
        let progress = timedProgress(for: segment, focus: focus, rawProgress: rawProgress)
        let target = Double(segment.depth - focus.depth - 1)
        return max(0, lerp(Double(segment.depth), target, progress))
    }

    /// A segment's eased progress on its class's schedule. Descendants are
    /// the segments strictly inside the focus wedge — a deeper segment
    /// under a sibling collapses with the shell, not with the reveal.
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

    /// A segment's fill opacity multiplier: the collapsing shell fades out
    /// over the first `shellFadeOutFraction` of its schedule, the focus
    /// holds through its sweep and fades before sealing into a center
    /// disk, and descendants stay opaque throughout.
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
