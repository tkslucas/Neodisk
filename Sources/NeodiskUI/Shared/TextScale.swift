// One scale for every workspace font; window chrome keeps the system size, like a browser's zoom.
// Views name a `NeoFont` instead of `.system(size:)`; AppKit text reads the scale directly.

import SwiftUI

/// Discrete rather than a slider: every step is a deliberate size and the keyboard walks them predictably.
enum TextScale {
    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static let standard: Double = 1.0

    /// The single gate for stored scales, so a hand-edited or other-build preference can't leave an unlisted
    /// size.
    static func snapped(_ value: Double) -> Double {
        steps.min(by: { abs($0 - value) < abs($1 - value) }) ?? standard
    }

    /// The next step up, or nil at the top — Zoom In disables there rather
    /// than looking live and doing nothing.
    static func larger(than value: Double) -> Double? {
        let current = snapped(value)
        return steps.first { $0 > current + 0.0001 }
    }

    /// The next step down, or nil at the bottom.
    static func smaller(than value: Double) -> Double? {
        let current = snapped(value)
        return steps.last { $0 < current - 0.0001 }
    }

    /// "100%" — the Settings picker's label.
    static func title(for value: Double) -> String {
        "\(Int((snapped(value) * 100).rounded()))%"
    }
}

// MARK: - Environment

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Set once at the workspace root; views that size boxes around text read it too.
    var neoTextScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

// MARK: - Fonts

/// A font written at its 100% size. Views name one of these instead of a
/// literal `.system(size:)`, so the workspace scale reaches every label.
struct NeoFont: Equatable, Sendable {
    var size: CGFloat
    var weight: Font.Weight

    init(_ size: CGFloat, weight: Font.Weight = .regular) {
        self.size = size
        self.weight = weight
    }

    func resolved(scale: CGFloat) -> Font {
        .system(size: size * scale, weight: weight)
    }

    /// The SwiftUI semantic styles this app used before the scale existed,
    /// pinned to their macOS point sizes so 100% renders exactly as it did.
    static let title = NeoFont(22)
    static let headline = NeoFont(13, weight: .semibold)
    static let body = NeoFont(13)
    static let callout = NeoFont(12)
    static let caption = NeoFont(10)
    static let caption2 = NeoFont(10, weight: .medium)
}

private struct NeoFontModifier: ViewModifier {
    @Environment(\.neoTextScale) private var scale
    let font: NeoFont

    func body(content: Content) -> some View {
        content.font(font.resolved(scale: scale))
    }
}

extension View {
    /// Where the workspace scale enters the view tree: the window's root, and the sheets it presents, which don't
    /// inherit an environment set beneath their modifier. Also the font for views that never name one (macOS's
    /// default is 13 pt, so 100% renders as before).
    func neoWorkspaceText(scale: CGFloat) -> some View {
        environment(\.neoTextScale, scale)
            .font(.system(size: NeoFont.body.size * scale))
    }

    func neoFont(_ font: NeoFont) -> some View {
        modifier(NeoFontModifier(font: font))
    }

    func neoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(NeoFontModifier(font: NeoFont(size, weight: weight)))
    }

    /// AppKit sizes chrome from the control size, not the label font, so a scaled title alone would overflow.
    /// Pass the `.small` a view chose as `base`; at 100% it is returned unchanged. SwiftUI controls ignore the
    /// workspace font: give a button's label `Text` a `.neoFont`, and use `NeoSegmentedPicker`/`NeoPopUpPicker`
    /// for pickers, whose titles SwiftUI never scales.
    func neoControlSize(base: ControlSize = .regular) -> some View {
        modifier(NeoControlSizeModifier(base: base))
    }
}

extension TextScale {
    /// AppKit's control sizes, smallest first. Bigger text walks up this
    /// ladder from the caller's base, clamped at the top.
    static let controlSizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]

    /// Unchanged at 100%, so a deliberately `.small` control is never promoted. From 175% a `.small` control
    /// reaches `.extraLarge`: a `.large` one is too short for 19-22 pt labels.
    static func controlSize(base: ControlSize, scale: CGFloat) -> ControlSize {
        let steps = switch scale {
        case ..<1.15: 0
        case ..<1.5: 1
        case ..<1.75: 2
        default: 3
        }
        let start = controlSizes.firstIndex(of: base) ?? 2
        return controlSizes[min(start + steps, controlSizes.count - 1)]
    }

    /// AppKit's label size for a control of `base` size (`NSFont.systemFontSize(for:)`), scaled: for AppKit
    /// controls and button labels, which don't take the workspace font.
    static func controlFontSize(base: ControlSize, scale: CGFloat) -> CGFloat {
        let standard: CGFloat = switch base {
        case .mini: 9
        case .small: 11
        default: 13
        }
        return standard * scale
    }
}

private struct NeoControlSizeModifier: ViewModifier {
    @Environment(\.neoTextScale) private var scale
    let base: ControlSize

    func body(content: Content) -> some View {
        content.controlSize(TextScale.controlSize(base: base, scale: scale))
    }
}
