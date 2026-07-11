//
//  SunburstHitTest.swift
//  SunburstCore
//
//  Polar hit-testing over laid-out segments. Points and sizes are plain
//  Doubles in the chart's local pixel space (origin top-left); NeodiskUI adds
//  thin CGPoint/CGSize overloads. Ported from Radix.
//

import Foundation

public enum SunburstHitTester {
    public nonisolated static func segment(
        atX x: Double,
        y: Double,
        width: Double,
        height: Double,
        segments: [SunburstSegment]
    ) -> SunburstSegment? {
        SunburstHitTestIndex(segments: segments)
            .segment(atX: x, y: y, width: width, height: height)
    }
}

public enum SunburstCenterHitTester {
    public nonisolated static func contains(
        atX x: Double,
        y: Double,
        width: Double,
        height: Double,
        radius: Double = SunburstLayout.centerRadius
    ) -> Bool {
        let centerX = width / 2
        let centerY = height / 2
        let maxRadius = min(width, height) / 2
        guard maxRadius > 0, radius > 0 else { return false }

        let dx = x - centerX
        let dy = y - centerY
        let distance = ((dx * dx) + (dy * dy)).squareRoot()
        return (distance / maxRadius) < radius
    }
}

public struct SunburstHitTestIndex: Sendable {
    private let rings: [Ring]

    public nonisolated init(segments: [SunburstSegment]) {
        var ringSegmentsByDepth: [Int: [SunburstSegment]] = [:]
        for segment in segments {
            ringSegmentsByDepth[segment.depth, default: []].append(segment)
        }

        rings = ringSegmentsByDepth
            .map { depth, segments in
                Ring(depth: depth, segments: segments)
            }
            .sorted { $0.depth < $1.depth }
    }

    public nonisolated func segment(
        atX x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> SunburstSegment? {
        guard !rings.isEmpty else { return nil }

        let centerX = width / 2
        let centerY = height / 2
        let dx = x - centerX
        let dy = y - centerY
        let maxRadius = min(width, height) / 2
        guard maxRadius > 0 else { return nil }

        let distance = ((dx * dx) + (dy * dy)).squareRoot()
        let normalizedDistance = distance / maxRadius
        guard let ring = rings.first(where: { $0.contains(normalizedDistance) }) else {
            return nil
        }

        var radians = atan2(dy, dx) + (.pi / 2)
        if radians < 0 {
            radians += (.pi * 2)
        }

        return ring.segment(containing: radians)
    }

    private struct Ring: Sendable {
        let depth: Int
        let minInnerRadius: Double
        let maxOuterRadius: Double
        let segments: [SunburstSegment]

        nonisolated init(depth: Int, segments: [SunburstSegment]) {
            self.depth = depth
            self.segments = segments.sorted { lhs, rhs in
                lhs.startAngle < rhs.startAngle
            }

            var minInnerRadius = Double.greatestFiniteMagnitude
            var maxOuterRadius: Double = 0
            for segment in segments {
                minInnerRadius = min(minInnerRadius, segment.innerRadius)
                maxOuterRadius = max(maxOuterRadius, segment.outerRadius)
            }

            self.minInnerRadius = minInnerRadius == .greatestFiniteMagnitude ? 0 : minInnerRadius
            self.maxOuterRadius = maxOuterRadius
        }

        nonisolated func contains(_ normalizedDistance: Double) -> Bool {
            // The band extends across the cosmetic ring gap so the space
            // between an arc and its children's ring belongs to the arc —
            // hovering it never drops the hover (the gaps are drawn, not
            // hit-tested).
            normalizedDistance >= minInnerRadius
                && normalizedDistance <= maxOuterRadius + SunburstLayout.ringGap
        }

        nonisolated func segment(containing radians: Double) -> SunburstSegment? {
            guard !segments.isEmpty else { return nil }

            var lowerBound = 0
            var upperBound = segments.count
            while lowerBound < upperBound {
                let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
                if segments[midpoint].startAngle <= radians {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }

            let candidateIndex = max(lowerBound - 1, 0)
            let candidate = segments[candidateIndex]
            guard radians >= candidate.startAngle,
                  radians <= candidate.endAngle else {
                return nil
            }
            return candidate
        }
    }
}
