//
//  SunburstColor.swift
//  SunburstCore
//
//  Branch-hue coloring for the sunburst's Largest tab:
//  each scan-root branch gets a stable hue (FNV-1a of the branch id), siblings
//  vary around it, and depth darkens/desaturates. Pure — HSB/RGB math and FNV
//  hashing only, no SwiftUI Color (that stays in NeodiskUI).
//
//  Stdlib only (no Foundation) so it stays Embedded-Swift-compatible for the
//  wasm build; SIMD3 and the FloatingPoint math are all stdlib.
//

public enum SunburstColorRole: Hashable, Sendable {
    case normal
    /// A file (or file-like leaf). Branch mode draws these gray: files are
    /// leaves, and graying them keeps the colored folder wedges legible.
    case file
    case aggregate
    case freeSpace
    /// The volume's hidden space (purgeable space, snapshots, unreadable
    /// files) — a quieter neutral than the free-space arc.
    case hiddenSpace
}

public struct SunburstColorToken: Hashable, Sendable {
    public let role: SunburstColorRole
    public let branchID: String
    public let localID: String
    public let branchIndex: Int
    public let branchCount: Int
    public let siblingIndex: Int
    public let siblingCount: Int
    public let depth: Int

    public init(
        branchID: String,
        localID: String,
        branchIndex: Int,
        branchCount: Int,
        siblingIndex: Int,
        siblingCount: Int,
        depth: Int,
        role: SunburstColorRole
    ) {
        self.role = role
        self.branchID = branchID
        self.localID = localID
        self.branchIndex = max(branchIndex, 0)
        self.branchCount = max(branchCount, 1)
        self.siblingIndex = max(siblingIndex, 0)
        self.siblingCount = max(siblingCount, 1)
        self.depth = max(depth, 0)
    }

    public static func single(
        id: String,
        depth: Int = 0,
        role: SunburstColorRole = .normal
    ) -> SunburstColorToken {
        SunburstColorToken(
            branchID: id,
            localID: id,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: role
        )
    }
}

public struct SunburstColorComponents: Equatable, Hashable, Sendable {
    public let hue: Double
    public let saturation: Double
    public let brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// How the branch resolver picks hues under the active palette. Standalone
/// from NeodiskUI's `VizPalette` so the resolver stays app-free; NeodiskUI
/// carries one of these values on each of its palettes. The raw color tables
/// live with the rest of the palette data in NeodiskUI — this type only
/// describes the strategy (and receives a table by value when one applies).
public struct SunburstPalette: Equatable, Sendable {
    public enum BranchHues: Equatable, Sendable {
        /// Hash-derived free hues — the classic continuous look. The scales
        /// tilt the resolver's saturation/brightness envelope so branch mode
        /// matches the palette's overall mood; (1, 1) is the classic default.
        case hashed(saturationScale: Double, brightnessScale: Double)
        /// Branch hues restricted to a fixed qualitative table (hash-stable
        /// per branch); depth and sibling variation move brightness only,
        /// never hue — hue identity is what the viewer must distinguish, and
        /// a curated table keeps its meaning.
        case table([SIMD3<Float>])
    }

    public let branchHues: BranchHues

    public init(branchHues: BranchHues) {
        self.branchHues = branchHues
    }

    public static let standard = SunburstPalette(
        branchHues: .hashed(saturationScale: 1, brightnessScale: 1)
    )
}

public enum SunburstColorResolver {
    private nonisolated static let fnvPrime: UInt64 = 1_099_511_628_211
    private nonisolated static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037

    /// The token's final fill as linear RGB, for layout-time resolution into
    /// `SunburstSegment.fillRGB`.
    public nonisolated static func rgb(
        for token: SunburstColorToken,
        palette: SunburstPalette = .standard
    ) -> SIMD3<Float> {
        rgb(from: components(for: token, palette: palette))
    }

    public nonisolated static func components(
        for token: SunburstColorToken,
        palette: SunburstPalette = .standard
    ) -> SunburstColorComponents {
        switch token.role {
        case .aggregate:
            return SunburstColorComponents(hue: 0, saturation: 0, brightness: 0.55)
        case .freeSpace:
            return SunburstColorComponents(hue: 0, saturation: 0, brightness: 0.62)
        case .hiddenSpace:
            return SunburstColorComponents(hue: 0, saturation: 0, brightness: 0.42)
        case .file:
            // Uniform gray with a slight brightness jitter so adjacent file
            // slices stay separable; depth darkens like the branch colors.
            let depthTone = min(Double(token.depth), 6)
            return SunburstColorComponents(
                hue: 0,
                saturation: 0,
                brightness: clamped(
                    0.62
                        - (depthTone * 0.03)
                        + (variantBrightnessOffset(for: token.localID) * 0.02),
                    lower: 0.46,
                    upper: 0.68
                )
            )
        case .normal:
            break
        }

        let saturationScale: Double
        let brightnessScale: Double
        switch palette.branchHues {
        case .table(let entries) where !entries.isEmpty:
            return tableComponents(for: token, entries: entries)
        case .table:
            // An empty table would divide by zero below; fall back to the
            // classic free hues.
            (saturationScale, brightnessScale) = (1, 1)
        case .hashed(let saturation, let brightness):
            (saturationScale, brightnessScale) = (saturation, brightness)
        }

        let branchHue = stableUnitInterval(for: token.branchID)
        let localUnit = stableUnitInterval(for: token.localID)
        let localVariant = centered(localUnit)
        let depthTone = min(Double(token.depth), 6)
        let hue = normalizedHue(
            branchHue
                + (localVariant * 0.11)
                + (Double(token.depth % 2) * 0.015)
        )
        // The palette scales move the whole envelope (base and clamps) so a
        // muted palette can sit below the classic floor; at scale 1 the
        // bounds reduce exactly to the classic 0.48…0.86 / 0.48…0.9.
        let saturation = clamped(
            (0.74 * saturationScale)
                - (depthTone * 0.035)
                + (localVariant * 0.08),
            lower: 0.48 * saturationScale,
            upper: min(0.86 * saturationScale, 1)
        )
        let brightness = clamped(
            (0.84 * brightnessScale)
                - (depthTone * 0.055)
                + (variantBrightnessOffset(for: token.localID) * 0.035),
            lower: min(0.48 * brightnessScale, 0.9),
            upper: min(0.9 * brightnessScale, 0.98)
        )

        return SunburstColorComponents(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )
    }

    /// Branch colors under a table palette: each branch picks a table entry
    /// (hash-stable per branch) and keeps that hue exactly — depth and
    /// sibling variation move brightness only, never the hue.
    private nonisolated static func tableComponents(
        for token: SunburstColorToken,
        entries: [SIMD3<Float>]
    ) -> SunburstColorComponents {
        let base = entries[Int(stableHash(for: token.branchID) % UInt64(entries.count))]
        let (hue, saturation, brightness) = hsb(fromRGB: base)
        let depthTone = min(Double(token.depth), 6)
        return SunburstColorComponents(
            hue: hue,
            saturation: clamped(saturation - depthTone * 0.02, lower: 0.2, upper: 1),
            brightness: clamped(
                brightness
                    - (depthTone * 0.055)
                    + (variantBrightnessOffset(for: token.localID) * 0.035),
                lower: 0.35,
                upper: 0.95
            )
        )
    }

    public nonisolated static func rgb(from components: SunburstColorComponents) -> SIMD3<Float> {
        let h = components.hue * 6
        let s = components.saturation
        let v = components.brightness
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return SIMD3<Float>(Float(r + m), Float(g + m), Float(b + m))
    }

    private nonisolated static func hsb(fromRGB rgb: SIMD3<Float>) -> (Double, Double, Double) {
        let r = Double(rgb.x), g = Double(rgb.y), b = Double(rgb.z)
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC == 0 ? 0 : delta / maxC
        return (hue, saturation, maxC)
    }

    private nonisolated static func variantBrightnessOffset(for key: String) -> Double {
        switch stableHash(for: key) % 4 {
        case 0:
            return 0.5
        case 1:
            return -0.5
        case 2:
            return 1
        default:
            return -1
        }
    }

    private nonisolated static func stableUnitInterval(for key: String) -> Double {
        Double(stableHash(for: key)) / Double(UInt64.max)
    }

    private nonisolated static func stableHash(for key: String) -> UInt64 {
        var hash = fnvOffsetBasis
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        return hash
    }

    private nonisolated static func centered(_ value: Double) -> Double {
        value - 0.5
    }

    private nonisolated static func normalizedHue(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private nonisolated static func clamped(
        _ value: Double,
        lower: Double,
        upper: Double
    ) -> Double {
        min(max(value, lower), upper)
    }
}
