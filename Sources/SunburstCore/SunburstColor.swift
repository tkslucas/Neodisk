//
//  SunburstColor.swift
//  SunburstCore
//
//  Branch coloring for the structural (Largest) mode: a folder's hue is the
//  midpoint of its global size interval — the tree is size-sorted, every
//  node owns a contiguous slice of the 0…1 scan-root coordinate, and the
//  slice's midpoint indexes the hue wheel (or a fixed palette table). Nested
//  folders occupy sub-slices of their parent, so related folders naturally
//  land on related hues, and saturation fades toward pastel with depth.
//  Pure — HSB/RGB math only, no SwiftUI Color (that stays in NeodiskUI).
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

/// A node's position in the scan-root color coordinate system: the midpoint
/// of its global size interval and its depth below the scan root. Both are
/// anchored to the scan root — never the drilled-in root — so drilling
/// preserves every color.
public struct SunburstColorToken: Hashable, Sendable {
    public let role: SunburstColorRole
    /// Midpoint of the node's global size interval, 0…1. The tree is
    /// size-sorted and every node's interval nests inside its parent's, so
    /// midpoints of related folders cluster. Drives the hue for `.normal`
    /// and the brightness jitter for `.file`; ignored by the fixed roles.
    public let midpoint: Double
    /// Depth below the scan root; scan-root children are depth 1. Drives
    /// the saturation fade (deeper rings go pastel, never darker).
    public let depth: Int

    public init(midpoint: Double, depth: Int, role: SunburstColorRole) {
        self.role = role
        self.midpoint = midpoint.isFinite ? midpoint : 0
        self.depth = max(depth, 0)
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

/// How the branch resolver turns a midpoint into a hue under the active
/// palette. Standalone from NeodiskUI's `VizPalette` so the resolver stays
/// app-free; NeodiskUI carries one of these values on each of its palettes.
public struct SunburstPalette: Equatable, Sendable {
    public enum BranchHues: Equatable, Sendable {
        /// The continuous hue wheel: hue equals the midpoint directly, and
        /// saturation follows the exact depth fade (see `components`). The
        /// scales tilt the whole envelope; (1, 1) is the plain look.
        case wheel(saturationScale: Double, brightnessScale: Double)
        /// Hues restricted to a fixed accent table: the midpoint quantizes
        /// into the hue-sorted table, so the wheel's geometry (children near
        /// their parent, siblings spreading with size) survives while every
        /// color stays in the scheme. Build via `quantized(_:)`, which
        /// hue-sorts the entries.
        case table([SIMD3<Float>])
    }

    public let branchHues: BranchHues

    public init(branchHues: BranchHues) {
        self.branchHues = branchHues
    }

    /// The resolver's app-free default (embedded demos, empty-table
    /// fallback): the plain continuous wheel.
    public static let standard = SunburstPalette(
        branchHues: .wheel(saturationScale: 1, brightnessScale: 1)
    )

    /// A table palette from a raw accent set: entries are sorted by hue so
    /// midpoint quantization walks the wheel in hue order — adjacent
    /// midpoints land on adjacent accents, keeping the parent/child hue
    /// kinship the wheel provides.
    public static func quantized(_ entries: [SIMD3<Float>]) -> SunburstPalette {
        let sorted = entries.sorted {
            SunburstColorResolver.hsb(fromRGB: $0).0 < SunburstColorResolver.hsb(fromRGB: $1).0
        }
        return SunburstPalette(branchHues: .table(sorted))
    }
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
                        + (jitterOffset(for: token.midpoint) * 0.02),
                    lower: 0.46,
                    upper: 0.68
                )
            )
        case .normal:
            break
        }

        // Scan-root children are depth 1; a degenerate depth-0 token (the
        // scan root itself) colors like the first ring.
        let depth = max(token.depth, 1)

        switch palette.branchHues {
        case .table(let entries) where !entries.isEmpty:
            return tableComponents(midpoint: token.midpoint, depth: depth, entries: entries)
        case .table:
            // An empty table would index out of bounds below; fall back to
            // the plain wheel.
            return wheelComponents(
                midpoint: token.midpoint, depth: depth,
                saturationScale: 1, brightnessScale: 1
            )
        case .wheel(let saturationScale, let brightnessScale):
            return wheelComponents(
                midpoint: token.midpoint, depth: depth,
                saturationScale: saturationScale, brightnessScale: brightnessScale
            )
        }
    }

    /// The continuous wheel: hue is the global midpoint itself, saturation
    /// halves its distance to 0.5 per level (first ring 0.75, approaching
    /// pastel 0.5), brightness stays full. Deeper never means darker.
    private nonisolated static func wheelComponents(
        midpoint: Double,
        depth: Int,
        saturationScale: Double,
        brightnessScale: Double
    ) -> SunburstColorComponents {
        SunburstColorComponents(
            hue: normalizedHue(midpoint),
            saturation: clamped(
                (0.5 + 0.5 * halving(depth)) * saturationScale,
                lower: 0, upper: 1
            ),
            brightness: clamped(brightnessScale, lower: 0, upper: 1)
        )
    }

    /// 2^-steps as an exact stdlib construction (no Foundation `exp2`).
    private nonisolated static func halving(_ steps: Int) -> Double {
        Double(sign: .plus, exponent: -min(max(steps, 0), 62), significand: 1)
    }

    /// A table palette: the midpoint quantizes into the hue-sorted table
    /// (each entry owns an equal share of the wheel), and depth applies the
    /// same halve-toward-pastel fade to the entry's own saturation — the
    /// first ring keeps the accent verbatim.
    private nonisolated static func tableComponents(
        midpoint: Double,
        depth: Int,
        entries: [SIMD3<Float>]
    ) -> SunburstColorComponents {
        let position = normalizedHue(midpoint) * Double(entries.count)
        let index = min(Int(position), entries.count - 1)
        let (hue, saturation, brightness) = hsb(fromRGB: entries[index])
        let fade = 0.5 + 0.5 * halving(depth - 1)
        return SunburstColorComponents(
            hue: hue,
            saturation: saturation * fade,
            brightness: brightness
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

    /// RGB → (hue, saturation, brightness), the exact inverse of
    /// `rgb(from:)` — shared with NeodiskUI's palette transforms.
    public nonisolated static func hsb(fromRGB rgb: SIMD3<Float>) -> (Double, Double, Double) {
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

    /// A deterministic ±1/±0.5 offset from the midpoint's bit pattern —
    /// adjacent file slices get distinct midpoints, so this separates them
    /// without any per-node identity.
    private nonisolated static func jitterOffset(for midpoint: Double) -> Double {
        var hash = fnvOffsetBasis
        var bits = midpoint.bitPattern
        for _ in 0..<8 {
            hash ^= bits & 0xFF
            hash &*= fnvPrime
            bits >>= 8
        }
        switch hash % 4 {
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
