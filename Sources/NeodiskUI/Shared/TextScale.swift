//
//  TextScale.swift
//  Neodisk
//
//  Workspace text size: one scale factor applied to every font the workspace
//  draws — locations sidebar, file lists, both visualizations, statistics,
//  status bar, tooltips. Window chrome (Settings, About, the menu bar,
//  alerts) keeps the system size, the way a browser's zoom leaves its own
//  chrome alone.
//
//  Views never write a literal `.system(size:)`; they name a `NeoFont` and
//  let `.neoFont` resolve it against the scale in the environment. AppKit
//  surfaces that draw their own text (the outline table, treemap labels)
//  read the scale directly — see OutlineRowMetrics and TreemapScene.
//

import SwiftUI

/// The discrete zoom steps ⌘+/⌘− walk and the Settings picker lists.
/// Discrete rather than a slider: every step is a size someone deliberately
/// chose, and the keyboard walks them predictably.
enum TextScale {
    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static let standard: Double = 1.0

    /// `value` snapped to the nearest step — the single gate a stored or
    /// restored scale passes through, so a hand-edited preference (or one
    /// written by a build with a different ladder) can never leave the UI at
    /// an unlisted size.
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
    /// The workspace text scale, set once at the workspace root. Every
    /// `neoFont` below resolves against it; views that size their own boxes
    /// around text (icon slots, row padding) read it too.
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
    func neoFont(_ font: NeoFont) -> some View {
        modifier(NeoFontModifier(font: font))
    }

    func neoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(NeoFontModifier(font: NeoFont(size, weight: weight)))
    }

    /// Grow a control with the text scale. AppKit sizes a control's chrome
    /// from its control size, not from its label's font, so a scaled title
    /// on its own would just overflow the capsule.
    ///
    /// `base` is the size the control had before the scale existed — pass
    /// the `.small` a view deliberately chose, and it steps up from there.
    /// At 100% this always returns `base` unchanged.
    func neoControlSize(base: ControlSize = .regular) -> some View {
        modifier(NeoControlSizeModifier(base: base))
    }
}

extension TextScale {
    /// AppKit's control sizes, smallest first. Bigger text walks up this
    /// ladder from the caller's base, clamped at the top.
    static let controlSizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]

    /// `base` grown for `scale`. Returns `base` unchanged at 100%, which is
    /// what lets `neoControlSize` be applied to a deliberately `.small`
    /// control without promoting it.
    static func controlSize(base: ControlSize, scale: CGFloat) -> ControlSize {
        let steps = switch scale {
        case ..<1.15: 0
        case ..<1.5: 1
        default: 2
        }
        let start = controlSizes.firstIndex(of: base) ?? 2
        return controlSizes[min(start + steps, controlSizes.count - 1)]
    }
}

private struct NeoControlSizeModifier: ViewModifier {
    @Environment(\.neoTextScale) private var scale
    let base: ControlSize

    func body(content: Content) -> some View {
        content.controlSize(TextScale.controlSize(base: base, scale: scale))
    }
}
