//
//  SunburstChartStyler.swift
//  Neodisk
//
//  Fill/stroke styles for sunburst segments: depth-faded fills, hover and
//  selection overlays. Ported from Radix; fills resolved at layout time
//  (kind/age modes) take precedence over the branch color resolver.
//

import SunburstCore
import SwiftUI

struct SunburstSegmentDrawingStyle {
    let fillBaseColor: Color
    let fillOpacity: Double
    let strokeColor: Color
    let strokeWidth: CGFloat

    var fillColor: Color {
        fillBaseColor.opacity(fillOpacity)
    }
}

enum SunburstChartStyler {
    static func baseStyle(
        for segment: SunburstSegment
    ) -> SunburstSegmentDrawingStyle {
        baseStyle(for: segment, effectiveDepth: Double(segment.depth))
    }

    /// Base style at a fractional ring depth — the zoom transition blends a
    /// segment's depth as it shifts rings, so the depth-faded fill opacity
    /// glides instead of popping a shade at the handoff.
    static func baseStyle(
        for segment: SunburstSegment,
        effectiveDepth: Double
    ) -> SunburstSegmentDrawingStyle {
        if segment.isAggregate {
            return SunburstSegmentDrawingStyle(
                fillBaseColor: Color(nsColor: .tertiaryLabelColor),
                fillOpacity: 0.22,
                strokeColor: Color(nsColor: .separatorColor).opacity(0.55),
                strokeWidth: 1
            )
        }

        let baseOpacity = standardOpacity(for: segment, depth: effectiveDepth)

        return SunburstSegmentDrawingStyle(
            fillBaseColor: baseColor(for: segment),
            fillOpacity: baseOpacity,
            strokeColor: Color(nsColor: .separatorColor).opacity(0.4),
            strokeWidth: 1
        )
    }

    static func selectionOverlayStyle(
        for segment: SunburstSegment,
        role: SunburstSelectionRole
    ) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetFillOpacity: Double
        let strokeColor: Color
        let strokeWidth: CGFloat

        switch role {
        case .ancestor:
            targetFillOpacity = min(base.fillOpacity + 0.04, 0.84)
            strokeColor = Color.white.opacity(0.22)
            strokeWidth = 1.5
        case .selected:
            targetFillOpacity = min(base.fillOpacity + 0.1, 0.9)
            strokeColor = Color.white.opacity(0.5)
            strokeWidth = 2.5
        }

        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetFillOpacity),
            strokeColor: strokeColor,
            strokeWidth: strokeWidth
        )
    }

    static func hoverOverlayStyle(for segment: SunburstSegment) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetFillOpacity = hoverFillOpacity(for: segment)
        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetFillOpacity),
            strokeColor: .primary.opacity(0.85),
            strokeWidth: 2.5
        )
    }

    private static func baseColor(for segment: SunburstSegment) -> Color {
        if segment.colorToken.role == .freeSpace {
            return Color(nsColor: .systemGray)
        }
        if segment.colorToken.role == .hiddenSpace {
            // Quieter than free space: the same neutral, but darker so the
            // two synthetic arcs stay distinguishable at a glance.
            return Color(nsColor: .darkGray)
        }
        if segment.colorToken.role == .aggregate {
            return Color(nsColor: .tertiaryLabelColor)
        }
        if let fillRGB = segment.fillRGB {
            return Color(
                red: Double(fillRGB.x),
                green: Double(fillRGB.y),
                blue: Double(fillRGB.z)
            )
        }

        return SunburstColorResolver.color(for: segment.colorToken)
    }

    private static func standardOpacity(for segment: SunburstSegment) -> Double {
        standardOpacity(for: segment, depth: Double(segment.depth))
    }

    private static func standardOpacity(for segment: SunburstSegment, depth: Double) -> Double {
        if segment.colorToken.role == .freeSpace {
            return 0.34
        }
        if segment.colorToken.role == .hiddenSpace {
            return 0.4
        }
        return max(0.24, 0.78 - (depth * 0.09) - (segment.isAggregate ? 0.16 : 0))
    }

    private static func hoverFillOpacity(for segment: SunburstSegment) -> Double {
        if segment.colorToken.role == .freeSpace {
            return 0.5
        }
        if segment.colorToken.role == .hiddenSpace {
            return 0.56
        }
        if segment.isAggregate {
            return 0.4
        }

        return min(standardOpacity(for: segment) + 0.18, 0.95)
    }

    private static func overlayOpacity(from baseOpacity: Double, to targetOpacity: Double) -> Double {
        guard targetOpacity > baseOpacity else { return 0 }
        let remainingOpacity = max(1 - baseOpacity, .leastNonzeroMagnitude)
        return min(max((targetOpacity - baseOpacity) / remainingOpacity, 0), 1)
    }
}
