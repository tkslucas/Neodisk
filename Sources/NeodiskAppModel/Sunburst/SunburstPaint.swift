// How a sunburst arc is painted (depth-faded fills, muted aggregate and space arcs, the hairline between arcs),
// for shells that draw the chart from SunburstCore's layout themselves.

import Foundation
import SunburstCore

package enum SunburstPaint {
    /// Rings drawn below the center, as on the Mac.
    package nonisolated static let depthLimit = 8

    /// Fill color and opacity; `depth` is fractional while a drill moves a ring, so its shade blends instead of
    /// popping at the handoff.
    package nonisolated static func fill(
        for segment: SunburstSegment,
        depth: Double,
        palette: VizPalette,
        isDark: Bool
    ) -> (rgb: SIMD3<Float>, opacity: Double) {
        switch segment.colorToken.role {
        case .freeSpace:
            return (SIMD3(0.56, 0.56, 0.58), 0.34)
        case .hiddenSpace:
            return (SIMD3(0.33, 0.33, 0.35), 0.4)
        case .aggregate:
            return (isDark ? SIMD3(0.6, 0.6, 0.62) : SIMD3(0.45, 0.45, 0.47), 0.22)
        default:
            let rgb = segment.fillRGB ?? SunburstColorResolver.rgb(for: segment.colorToken, palette: palette.sunburst)
            let opacity = max(0.24, 0.78 - depth * 0.09 - (segment.isAggregate ? 0.16 : 0))
            return (rgb, opacity)
        }
    }

    /// The hairline between arcs, as RGBA.
    package nonisolated static func separator(isDark: Bool) -> SIMD4<Float> {
        isDark ? SIMD4(1, 1, 1, 0.08) : SIMD4(0, 0, 0, 0.1)
    }
}
