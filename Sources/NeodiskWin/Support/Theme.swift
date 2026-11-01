// The Windows 11 color tokens for the system's light or dark app theme and accent, read from the registry
// and re-read when the system announces a change ("ImmersiveColorSet").

import CNeodiskWin
import Foundation
import WinSDK

struct RGBA: Equatable {
    var r: Float
    var g: Float
    var b: Float
    var a: Float = 1

    init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 0xRRGGBB with an alpha.
    init(hex: UInt32, alpha: Float = 1) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
        a = alpha
    }

    func withAlpha(_ alpha: Float) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    /// This color painted over an opaque `base`.
    func over(_ base: RGBA) -> RGBA {
        RGBA(r: r * a + base.r * (1 - a), g: g * a + base.g * (1 - a), b: b * a + base.b * (1 - a), a: 1)
    }

    var ndw: NdwRGBA { NdwRGBA(r: r, g: g, b: b, a: a) }
    var colorref: COLORREF {
        COLORREF(UInt32(r * 255) | UInt32(g * 255) << 8 | UInt32(b * 255) << 16)
    }
    var simd: SIMD3<Float> { SIMD3(r, g, b) }
}

struct Theme: Equatable {
    let isDark: Bool
    /// The system accent and its lighter and darker steps (Light3 … Dark3).
    let accent: RGBA
    let accentLight1: RGBA
    let accentLight2: RGBA
    let accentLight3: RGBA
    let accentDark1: RGBA
    let accentDark2: RGBA

    @MainActor static private(set) var current = Theme.load()

    /// Re-reads the system theme; true when it changed.
    @MainActor @discardableResult
    static func reload() -> Bool {
        let fresh = Theme.load()
        guard fresh != current else { return false }
        current = fresh
        return true
    }

    // MARK: - Tokens (WinUI's light and dark theme resources)

    var textPrimary: RGBA { isDark ? RGBA(hex: 0xFFFFFF) : RGBA(hex: 0x000000, alpha: 0.894) }
    var textSecondary: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.786) : RGBA(hex: 0x000000, alpha: 0.62) }
    var textTertiary: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.545) : RGBA(hex: 0x000000, alpha: 0.446) }
    var textDisabled: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.363) : RGBA(hex: 0x000000, alpha: 0.361) }
    /// Hover and pressed fills behind subtle (borderless) buttons and list items.
    var subtleHover: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.061) : RGBA(hex: 0x000000, alpha: 0.037) }
    var subtlePressed: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.042) : RGBA(hex: 0x000000, alpha: 0.024) }
    var controlFill: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.061) : RGBA(hex: 0xFFFFFF, alpha: 0.7) }
    var controlFillHover: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.084) : RGBA(hex: 0xF9F9F9, alpha: 0.5) }
    var controlStroke: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.07) : RGBA(hex: 0x000000, alpha: 0.059) }
    var controlStrongStroke: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.544) : RGBA(hex: 0x000000, alpha: 0.446) }
    var divider: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.084) : RGBA(hex: 0x000000, alpha: 0.08) }
    /// The window's solid base where Mica isn't available.
    var solidBackground: RGBA { isDark ? RGBA(hex: 0x202020) : RGBA(hex: 0xF3F3F3) }
    /// The content layer, opaque: the layer fill as it composes over Mica.
    var layer: RGBA { isDark ? RGBA(hex: 0x272727) : RGBA(hex: 0xF9F9F9) }
    var layerStroke: RGBA { isDark ? RGBA(hex: 0x000000, alpha: 0.1) : RGBA(hex: 0x000000, alpha: 0.059) }
    /// Text boxes and other input fields on the layer.
    var inputFill: RGBA { isDark ? RGBA(hex: 0x2D2D2D) : RGBA(hex: 0xFFFFFF) }
    var inputFillFocused: RGBA { isDark ? RGBA(hex: 0x1F1F1F) : RGBA(hex: 0xFFFFFF) }
    var accentFill: RGBA { isDark ? accentLight2 : accentDark1 }
    var accentFillHover: RGBA { (isDark ? accentLight2 : accentDark1).withAlpha(0.9) }
    var accentText: RGBA { isDark ? accentLight3 : accentDark2 }
    var textOnAccent: RGBA { isDark ? RGBA(hex: 0x000000) : RGBA(hex: 0xFFFFFF) }
    /// The progress and capacity tracks.
    var track: RGBA { isDark ? RGBA(hex: 0xFFFFFF, alpha: 0.16) : RGBA(hex: 0x000000, alpha: 0.12) }
    var focusOuter: RGBA { isDark ? RGBA(hex: 0xFFFFFF) : RGBA(hex: 0x000000, alpha: 0.894) }
    var focusInner: RGBA { isDark ? RGBA(hex: 0x000000, alpha: 0.7) : RGBA(hex: 0xFFFFFF) }
    var caution: RGBA { isDark ? RGBA(hex: 0xFCE100) : RGBA(hex: 0x9D5D00) }

    // MARK: - Reading the system settings

    private static func load() -> Theme {
        let lightApps = registryDWORD(
            path: "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", value: "AppsUseLightTheme"
        )
        let isDark: Bool = if let forced = ProcessInfo.processInfo.environment["NEODISK_THEME"] {
            forced == "dark"
        } else {
            lightApps == 0
        }
        // AccentPalette: eight RGBA entries, Light3 through Dark3, then an unused one.
        var palette = [RGBA]()
        if let bytes = registryBinary(
            path: "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent", value: "AccentPalette"
        ), bytes.count >= 28 {
            for index in 0..<7 {
                let offset = index * 4
                palette.append(RGBA(
                    r: Float(bytes[offset]) / 255, g: Float(bytes[offset + 1]) / 255, b: Float(bytes[offset + 2]) / 255
                ))
            }
        } else {
            // The default blue.
            palette = [0x99EBFF, 0x4CC2FF, 0x0091F8, 0x0078D4, 0x0067C0, 0x003E92, 0x001A68].map { RGBA(hex: $0) }
        }
        return Theme(
            isDark: isDark,
            accent: palette[3],
            accentLight1: palette[2],
            accentLight2: palette[1],
            accentLight3: palette[0],
            accentDark1: palette[4],
            accentDark2: palette[5]
        )
    }

    private static func registryDWORD(path: String, value: String) -> DWORD? {
        var data: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = withWide(path) { path in
            withWide(value) { value in
                RegGetValueW(hkeyCurrentUser, path, value, DWORD(RRF_RT_REG_DWORD), nil, &data, &size)
            }
        }
        return status == ERROR_SUCCESS ? data : nil
    }

    private static func registryBinary(path: String, value: String) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var size = DWORD(buffer.count)
        let status = withWide(path) { path in
            withWide(value) { value in
                RegGetValueW(hkeyCurrentUser, path, value, DWORD(RRF_RT_REG_BINARY), nil, &buffer, &size)
            }
        }
        return status == ERROR_SUCCESS ? Array(buffer.prefix(Int(size))) : nil
    }
}
