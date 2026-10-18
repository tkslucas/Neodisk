import SwiftUI

/// The fill is the only progress signal; the drifting stripes only say the app is alive. The phase comes
/// from the clock via `TimelineView` because a `repeatForever` animation stutters on frequent re-renders.
struct StripedProgressBar: View {
    @Environment(\.neoTextScale) private var textScale

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
        .frame(height: (5 * textScale).rounded())
    }
}

/// One extra period of overdraw per side, so an offset of up to one period never exposes a gap.
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
