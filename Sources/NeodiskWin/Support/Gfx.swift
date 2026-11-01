// Drawing for the custom-drawn chrome: layout happens in device-independent pixels (1/96 inch), and this
// scales each call to the window's DPI before it reaches Direct2D.

import CNeodiskWin
import Foundation

struct TextStyle {
    var size: Float
    var weight: Int32 = 400
    var family: NdwFontFamily = NDW_FONT_TEXT
    var align: NdwTextAlign = NDW_ALIGN_LEADING
    var tabular = false

    /// The Windows 11 type ramp: body 14, caption 12, body strong, subtitle 20.
    static let body = TextStyle(size: 14)
    static let bodyStrong = TextStyle(size: 14, weight: 600)
    static let caption = TextStyle(size: 12)
    static let captionNumeric = TextStyle(size: 12, tabular: true)
    static let subtitle = TextStyle(size: 20, weight: 600, family: NDW_FONT_DISPLAY)

    func aligned(_ align: NdwTextAlign) -> TextStyle {
        var copy = self
        copy.align = align
        return copy
    }

    func scaled(_ scale: Float) -> NdwTextStyle {
        NdwTextStyle(
            size: size * scale, weight: weight, family: Int32(family.rawValue), align: Int32(align.rawValue),
            tabular: tabular ? 1 : 0
        )
    }
}

/// Segoe Fluent Icons code points.
enum Glyph: UInt16 {
    case back = 0xE72B
    case forward = 0xE72A
    case up = 0xE74A
    case refresh = 0xE72C
    case stop = 0xE71A
    case search = 0xE721
    case folder = 0xE8B7
    case openFolder = 0xE838
    case hardDrive = 0xEDA2
    case usb = 0xE88E
    case networkDrive = 0xE8CE
    case home = 0xE80F
    case more = 0xE712
    case settings = 0xE713
    case chevronRight = 0xE76C
    case chevronDown = 0xE70D
    case treemap = 0xF0E2
    case sunburst = 0xEB05
    case add = 0xE710
    case warning = 0xE7BA
    case clear = 0xE894
    case document = 0xE8A5

    var text: String { String(utf16CodeUnits: [rawValue], count: 1) }
}

@MainActor
struct Gfx {
    let raw: OpaquePointer
    /// Pixels per DIP.
    let scale: Float

    private func pixels(_ rect: CGRect) -> NdwRect {
        NdwRect(
            x: Float(rect.minX) * scale, y: Float(rect.minY) * scale,
            w: Float(rect.width) * scale, h: Float(rect.height) * scale
        )
    }

    /// Snapped to whole pixels, for hairlines and edges that should stay crisp.
    private func snapped(_ rect: CGRect) -> NdwRect {
        let s = Double(scale)
        let x0 = (rect.minX * s).rounded(), y0 = (rect.minY * s).rounded()
        let x1 = (rect.maxX * s).rounded(), y1 = (rect.maxY * s).rounded()
        return NdwRect(x: Float(x0), y: Float(y0), w: Float(x1 - x0), h: Float(y1 - y0))
    }

    func fill(_ rect: CGRect, _ color: RGBA, radius: Double = 0) {
        if radius > 0 {
            ndw_fill_rounded(raw, snapped(rect), Float(radius) * scale, color.ndw)
        } else {
            ndw_fill_rect(raw, snapped(rect), color.ndw)
        }
    }

    func stroke(_ rect: CGRect, _ color: RGBA, radius: Double, width: Double = 1) {
        // Hairlines stay one device pixel at any scale.
        let pixelWidth = max(1, (Float(width) * scale).rounded(.down))
        ndw_stroke_rounded(raw, snapped(rect), Float(radius) * scale, pixelWidth, color.ndw)
    }

    func ellipse(_ rect: CGRect, _ color: RGBA) {
        ndw_fill_ellipse(raw, pixels(rect), color.ndw)
    }

    func hairline(x0: Double, y0: Double, x1: Double, y1: Double, _ color: RGBA) {
        let s = Double(scale)
        // Centered on a pixel row or column.
        let px0 = Float((x0 * s).rounded(.down) + 0.5), py0 = Float((y0 * s).rounded(.down) + 0.5)
        let px1 = Float((x1 * s).rounded(.down) + 0.5), py1 = Float((y1 * s).rounded(.down) + 0.5)
        ndw_line(raw, px0, py0, px1, py1, 1, color.ndw)
    }

    func stripes(_ rect: CGRect, radius: Double, period: Double, phase: Double, _ color: RGBA) {
        ndw_fill_stripes(raw, pixels(rect), Float(radius) * scale, Float(period) * scale, Float(phase) * scale, color.ndw)
    }

    func clip(_ rect: CGRect, _ body: () -> Void) {
        ndw_push_clip(raw, snapped(rect))
        body()
        ndw_pop_clip(raw)
    }

    func text(_ string: String, in rect: CGRect, style: TextStyle = .body, color: RGBA) {
        guard !string.isEmpty else { return }
        let units = Array(string.utf16)
        units.withUnsafeBufferPointer { buffer in
            ndw_text(raw, buffer.baseAddress, Int32(buffer.count), pixels(rect), style.scaled(scale), color.ndw)
        }
    }

    func icon(_ glyph: Glyph, in rect: CGRect, size: Float = 16, color: RGBA) {
        text(glyph.text, in: rect, style: TextStyle(size: size, family: NDW_FONT_ICONS, align: NDW_ALIGN_CENTER), color: color)
    }

    /// Fluent's keyboard focus visual: a 2 px outer stroke and a 1 px inner one, just outside the control.
    func focusRing(_ rect: CGRect, radius: Double, theme: Theme) {
        stroke(rect.insetBy(dx: -3, dy: -3), theme.focusOuter, radius: radius + 3, width: 2)
        stroke(rect.insetBy(dx: -1, dy: -1), theme.focusInner, radius: radius + 1, width: 1)
    }

    /// The width `string` takes in DIPs.
    static func textWidth(_ string: String, style: TextStyle = .body) -> Double {
        guard !string.isEmpty else { return 0 }
        let units = Array(string.utf16)
        return units.withUnsafeBufferPointer { buffer in
            Double(ndw_text_width(buffer.baseAddress, Int32(buffer.count), style.scaled(1)))
        }
    }
}
