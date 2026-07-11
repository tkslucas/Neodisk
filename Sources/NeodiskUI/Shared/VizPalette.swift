//
//  VizPalette.swift
//  Neodisk
//
//  The complete set of colors the visualization draws with — file-kind hues,
//  the fixed category colors, and the modification-age ramp. Two instances:
//  `.standard` (the default rainbow, tuned to look like Disk Inventory X) and
//  `.colorblind`, which the Settings toggle swaps in.
//
//  The colorblind set uses the Okabe-Ito qualitative palette (designed to stay
//  distinct under deuteranopia/protanopia/tritanopia) for the categorical kind
//  and category colors, and the viridis ramp for age — perceptually uniform,
//  colorblind-safe, and monotonic in lightness so it still reads in greyscale.
//  Neutral greys (other/directory/free-space) are already CVD-safe and shared.
//

import SwiftUI
import simd
import SunburstCore

struct VizPalette: Sendable, Equatable {
    /// Rank-ordered hues for the Types kind mode: the largest kind gets the
    /// first (most recognizable) color. Beyond this many kinds, cells fall
    /// back to the neutral "other" grey.
    let kindPalette: [SIMD3<Float>]
    /// Fixed colors for the Categories kind mode, keyed by category id — a
    /// category keeps its color regardless of size rank.
    let categoryRGB: [String: SIMD3<Float>]
    /// Age-bucket colors, indexed by `AgeBucket.rawValue`.
    let ageRamp: [SIMD3<Float>]

    func ageRGB(_ bucket: AgeBucket) -> SIMD3<Float> {
        ageRamp.indices.contains(bucket.rawValue) ? ageRamp[bucket.rawValue] : FileKindCatalog.otherRGB
    }

    func ageColor(_ bucket: AgeBucket) -> Color {
        let rgb = ageRGB(bucket)
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// The default rainbow palette — the values that live on FileKindCatalog
    /// and AgeBucket, gathered here so both palettes select the same way.
    static let standard = VizPalette(
        kindPalette: FileKindCatalog.palette,
        categoryRGB: FileKindCatalog.categoryRGB,
        ageRamp: AgeBucket.allCases.map(\.rgb)
    )

    /// Okabe-Ito kinds/categories + viridis age ramp. The kind hues are the
    /// same Okabe-Ito set the sunburst's colorblind branch mode draws from,
    /// so both select from one source (`SunburstColorblindKindTable`).
    static let colorblind = VizPalette(
        kindPalette: SunburstColorblindKindTable.kinds,
        categoryRGB: [
            "cat-video": SIMD3(0.000, 0.447, 0.698),      // blue
            "cat-image": SIMD3(0.000, 0.620, 0.451),      // bluish green
            "cat-audio": SIMD3(0.337, 0.706, 0.914),      // sky blue
            "cat-docs": SIMD3(0.941, 0.894, 0.259),       // yellow
            "cat-archive": SIMD3(0.902, 0.624, 0.000),    // orange
            "cat-code": SIMD3(0.800, 0.475, 0.655),       // reddish purple
            "cat-data": SIMD3(0.200, 0.133, 0.533),       // indigo
            "cat-apps": SIMD3(0.835, 0.369, 0.000),       // vermillion
            "cat-summarized": SIMD3(0.267, 0.667, 0.600), // teal
            "cat-system": SIMD3(0.867, 0.800, 0.467),     // sand
            "cat-other": FileKindCatalog.otherRGB,
        ],
        // viridis, dark→bright, so the oldest files glow brightest and the
        // ramp stays monotonic in lightness (legible in greyscale / for CVD).
        ageRamp: [
            SIMD3(0.267, 0.005, 0.329), // day    — newest
            SIMD3(0.255, 0.267, 0.529), // week
            SIMD3(0.165, 0.471, 0.557), // month
            SIMD3(0.133, 0.659, 0.518), // quarter
            SIMD3(0.478, 0.820, 0.318), // year
            SIMD3(0.992, 0.906, 0.145), // older  — oldest
            FileKindCatalog.otherRGB,   // unknown
        ]
    )

    /// Which of SunburstCore's qualitative color sets the branch-hue resolver
    /// should draw with under this palette.
    var sunburst: SunburstPalette {
        self == .colorblind ? .colorblind : .standard
    }
}
