//
//  SunburstGeometry.swift
//  Neodisk
//
//  The SwiftUI `Path` construction for the sunburst's arcs. The color style
//  and `styled` fill pass live in NeodiskAppModel (SunburstStyling.swift);
//  the layout, grouping, hit-testing, branch-hue math, and zoom remap in
//  SunburstCore.
//

import SwiftUI
import NeodiskKit
import SunburstCore
import NeodiskAppModel

enum SunburstRenderer {
    nonisolated static func path(for segment: SunburstSegment, in size: CGSize) -> Path {
        path(
            startRadians: segment.startAngle,
            endRadians: segment.endAngle,
            innerRadius: segment.innerRadius,
            outerRadius: segment.outerRadius,
            in: size
        )
    }

    /// Same arc construction for transient geometry (the zoom transition's
    /// remapped arcs), which is not backed by a SunburstSegment.
    nonisolated static func path(for arc: SunburstZoomArc, in size: CGSize) -> Path {
        path(
            startRadians: arc.startRadians,
            endRadians: arc.endRadians,
            innerRadius: arc.innerRadius,
            outerRadius: arc.outerRadius,
            in: size
        )
    }

    private nonisolated static func path(
        startRadians: Double,
        endRadians: Double,
        innerRadius: Double,
        outerRadius: Double,
        in size: CGSize
    ) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        let (seamStart, seamEnd) = SunburstArcGeometry.seamInsetAngles(
            startRadians: startRadians,
            endRadians: endRadians,
            innerRadius: innerRadius,
            outerRadius: outerRadius
        )
        let innerRadius = maxRadius * CGFloat(innerRadius)
        let outerRadius = maxRadius * CGFloat(outerRadius)

        let start = seamStart - (.pi / 2)
        let end = seamEnd - (.pi / 2)

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(start),
            endAngle: .radians(end),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(end),
            endAngle: .radians(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}
