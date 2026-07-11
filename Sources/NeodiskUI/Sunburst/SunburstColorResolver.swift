//
//  SunburstColorResolver.swift
//  Neodisk
//
//  Branch-hue coloring for the sunburst's Largest tab, ported from Radix:
//  each scan-root branch gets a stable hue (FNV-1a of the branch id), siblings
//  vary around it, and depth darkens/desaturates. Pure — zero app coupling.
//

import SwiftUI
import NeodiskKit

nonisolated enum SunburstColorRole: Hashable, Sendable {
    case normal
    /// A file (or file-like leaf). Branch mode draws these gray, DaisyDisk
    /// style: files are leaves, and graying them keeps the colored folder
    /// wedges legible.
    case file
    case aggregate
    case freeSpace
    /// The volume's hidden space (purgeable space, snapshots, unreadable
    /// files) — a quieter neutral than the free-space arc.
    case hiddenSpace
}

nonisolated struct SunburstColorToken: Hashable, Sendable {
    let role: SunburstColorRole
    let branchID: String
    let localID: String
    let branchIndex: Int
    let branchCount: Int
    let siblingIndex: Int
    let siblingCount: Int
    let depth: Int

    init(
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

    static func single(
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

nonisolated struct SunburstColorComponents: Equatable, Hashable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    nonisolated var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

nonisolated enum SunburstColorResolver {
    private nonisolated static let fnvPrime: UInt64 = 1_099_511_628_211
    private nonisolated static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037

    nonisolated static func color(
        for token: SunburstColorToken,
        palette: VizPalette = .standard
    ) -> Color {
        components(for: token, palette: palette).color
    }

    /// The token's final fill as linear RGB, for layout-time resolution into
    /// `SunburstSegment.fillRGB`.
    nonisolated static func rgb(
        for token: SunburstColorToken,
        palette: VizPalette = .standard
    ) -> SIMD3<Float> {
        rgb(from: components(for: token, palette: palette))
    }

    /// The color the sunburst's branch mode draws an arbitrary node with —
    /// the status-bar swatch must agree with the chart. `effectiveRootID` is
    /// the drilled-in root: segment depth is measured from it, while the hue
    /// family always derives from the scan-root branch.
    nonisolated static func branchColor(
        forNodeID nodeID: String,
        in treeStore: FileTreeStore,
        effectiveRootID: String,
        palette: VizPalette = .standard
    ) -> Color {
        let branchID = SunburstLayout.topLevelBranchID(for: nodeID, in: treeStore) ?? nodeID
        let depth = max(
            treeStore.path(to: nodeID).count - treeStore.path(to: effectiveRootID).count - 1,
            0
        )
        let token = SunburstColorToken(
            branchID: branchID,
            localID: nodeID,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: treeStore.node(id: nodeID)?.isSunburstFolder(in: treeStore) == false ? .file : .normal
        )
        return color(for: token, palette: palette)
    }

    nonisolated static func components(
        for token: SunburstColorToken,
        palette: VizPalette = .standard
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

        if palette == .colorblind {
            return colorblindComponents(for: token)
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
        let saturation = clamped(
            0.74
                - (depthTone * 0.035)
                + (localVariant * 0.08),
            lower: 0.48,
            upper: 0.86
        )
        let brightness = clamped(
            0.84
                - (depthTone * 0.055)
                + (variantBrightnessOffset(for: token.localID) * 0.035),
            lower: 0.48,
            upper: 0.9
        )

        return SunburstColorComponents(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )
    }

    /// Branch colors under the colorblind palette: hue identity is what a
    /// colorblind viewer must distinguish, so branches pick from the same
    /// Okabe-Ito set the kind mode uses (hash-stable per branch) and keep
    /// that hue exactly — depth and sibling variation move brightness only,
    /// never the hue.
    private nonisolated static func colorblindComponents(
        for token: SunburstColorToken
    ) -> SunburstColorComponents {
        let entries = VizPalette.colorblind.kindPalette
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

    private nonisolated static func rgb(from components: SunburstColorComponents) -> SIMD3<Float> {
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
