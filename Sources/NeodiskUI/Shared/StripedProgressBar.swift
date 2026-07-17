//
//  StripedProgressBar.swift
//  Neodisk
//

import SwiftUI

/// The scan progress bar: a determinate capsule fill with a continuously
/// drifting diagonal-stripe sheen over the filled portion. The fill level is
/// the only progress signal (determinate, monotone, full means done — see the
/// product constraints in AGENTS.md); the stripes carry exactly one bit of
/// information: the app is alive, not frozen. They drift while `isActive`,
/// freeze when the scan is stopped, and are static from the start when the
/// user has Reduce Motion enabled.
///
/// The drift phase is derived from the wall clock via `TimelineView`, not an
/// animated `@State`: scan metrics re-render this view many times a second,
/// and a `repeatForever` animation restarted on re-render freezes or
/// stutters. A clock-derived phase is immune to re-renders.
struct StripedProgressBar: View {
    var value: Double
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distance between stripe leading edges.
    private let period: CGFloat = 9
    private let stripeThickness: CGFloat = 3.5
    /// Drift speed in points per second (two periods per second).
    private let driftSpeed: Double = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion)) { context in
            let phase = CGFloat(
                (context.date.timeIntervalSinceReferenceDate * driftSpeed)
                    .truncatingRemainder(dividingBy: Double(period))
            )
            GeometryReader { geometry in
                let fillWidth = max(0, min(1, value)) * geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .overlay(
                            DiagonalStripes(period: period, thickness: stripeThickness)
                                .fill(.white.opacity(0.28))
                                .offset(x: phase)
                        )
                        .clipShape(Capsule())
                        .frame(width: fillWidth)
                        .animation(.linear(duration: 0.2), value: fillWidth)
                }
            }
        }
        .frame(height: 5)
    }
}

/// Parallel 45° stripe bands covering `rect` with one extra period of
/// overdraw on each side, so a horizontal offset of up to one period never
/// exposes a gap.
private struct DiagonalStripes: Shape {
    var period: CGFloat
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let slant = rect.height
        var x = rect.minX - slant - period
        while x < rect.maxX + period {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + slant, y: rect.minY))
            path.addLine(to: CGPoint(x: x + slant + thickness, y: rect.minY))
            path.addLine(to: CGPoint(x: x + thickness, y: rect.maxY))
            path.closeSubpath()
            x += period
        }
        return path
    }
}
