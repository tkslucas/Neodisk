//
//  VizPalette.swift
//  Neodisk
//
//  The complete set of colors the visualization draws with — file-kind hues,
//  the fixed category colors, the modification-age ramp, and the branch-hue
//  strategy the sunburst resolver uses. Every raw color table lives in this
//  file; the Settings palette picker selects one of the named instances in
//  `VizPalette.all`.
//
//  Classic, Vivid, and Pastel share one hue-role ordering (index 0 is the
//  blue slot, 1 the red slot, …), so category colors and the age ramp derive
//  from the kind table through the shared role maps below — switching between
//  them never changes what a color means, only how it looks. Earth follows
//  the same role order with muted natural tones. Colorblind uses the
//  Okabe-Ito qualitative palette (designed to stay distinct under
//  deuteranopia/protanopia/tritanopia) with its own role map, and the viridis
//  ramp for age — perceptually uniform and monotonic in lightness so it still
//  reads in greyscale.
//

import SwiftUI
import simd
import SunburstCore

struct VizPalette: Sendable, Equatable, Identifiable {
    /// Stable identifier, persisted in the "vizPalette" preference.
    let id: String
    /// Display name for the Settings picker; localized at the point of use.
    let title: String
    /// Rank-ordered hues for the Types kind mode: the largest kind gets the
    /// first (most recognizable) color. Beyond this many kinds, cells fall
    /// back to the neutral "other" grey.
    let kindPalette: [SIMD3<Float>]
    /// Fixed colors for the Categories kind mode, keyed by category id — a
    /// category keeps its color regardless of size rank.
    let categoryRGB: [String: SIMD3<Float>]
    /// Age-bucket colors, indexed by `AgeBucket.rawValue`.
    let ageRamp: [SIMD3<Float>]
    /// How SunburstCore's branch-hue resolver draws under this palette.
    let sunburst: SunburstPalette

    func ageRGB(_ bucket: AgeBucket) -> SIMD3<Float> {
        ageRamp.indices.contains(bucket.rawValue) ? ageRamp[bucket.rawValue] : FileKindCatalog.otherRGB
    }

    func ageColor(_ bucket: AgeBucket) -> Color {
        Color(rgb: ageRGB(bucket))
    }

    // MARK: - Registry

    /// Every selectable palette, in the order the Settings picker lists them.
    static let all: [VizPalette] = [.standard, .vivid, .pastel, .earth, .colorblind]

    /// The palette persisted under `id`, or the default for unknown ids
    /// (never fails: a stale preference falls back gracefully).
    static func named(_ id: String) -> VizPalette {
        all.first { $0.id == id } ?? .standard
    }

    static let standard = VizPalette(
        id: "standard",
        title: "Classic",
        kinds: [
            SIMD3(0.31, 0.48, 0.95), // blue
            SIMD3(0.90, 0.28, 0.26), // red
            SIMD3(0.30, 0.75, 0.32), // green
            SIMD3(0.83, 0.29, 0.83), // magenta
            SIMD3(0.95, 0.78, 0.20), // yellow
            SIMD3(0.25, 0.78, 0.82), // cyan
            SIMD3(0.95, 0.52, 0.19), // orange
            SIMD3(0.56, 0.36, 0.90), // purple
            SIMD3(0.20, 0.60, 0.50), // teal
            SIMD3(0.94, 0.45, 0.65), // pink
            SIMD3(0.62, 0.80, 0.24), // lime
            SIMD3(0.62, 0.44, 0.28), // brown
            SIMD3(0.42, 0.56, 0.14), // olive
            SIMD3(0.55, 0.27, 0.42), // plum
        ],
        sunburst: .standard
    )

    /// The classic hues punched up (saturation and brightness raised in HSB)
    /// — reads especially well under the cushion's shading, which multiplies
    /// every color down.
    static let vivid = VizPalette(
        id: "vivid",
        title: "Vivid",
        kinds: [
            SIMD3(0.16, 0.38, 1.00), // blue
            SIMD3(1.00, 0.14, 0.12), // red
            SIMD3(0.21, 0.84, 0.24), // green
            SIMD3(0.93, 0.18, 0.93), // magenta
            SIMD3(1.00, 0.78, 0.02), // yellow
            SIMD3(0.12, 0.86, 0.92), // cyan
            SIMD3(1.00, 0.44, 0.01), // orange
            SIMD3(0.53, 0.25, 1.00), // purple
            SIMD3(0.11, 0.67, 0.53), // teal
            SIMD3(1.00, 0.34, 0.61), // pink
            SIMD3(0.65, 0.90, 0.12), // lime
            SIMD3(0.69, 0.44, 0.22), // brown
            SIMD3(0.43, 0.63, 0.04), // olive
            SIMD3(0.62, 0.22, 0.43), // plum
        ],
        sunburst: SunburstPalette(
            branchHues: .hashed(saturationScale: 1.15, brightnessScale: 1.06)
        )
    )

    /// The classic hues softened (half the saturation, brightness raised) —
    /// gentle against the dark canvas.
    static let pastel = VizPalette(
        id: "pastel",
        title: "Pastel",
        kinds: [
            SIMD3(0.66, 0.75, 1.00), // blue
            SIMD3(1.00, 0.66, 0.64), // red
            SIMD3(0.66, 0.94, 0.67), // green
            SIMD3(1.00, 0.67, 1.00), // magenta
            SIMD3(1.00, 0.91, 0.61), // yellow
            SIMD3(0.65, 0.98, 1.00), // cyan
            SIMD3(1.00, 0.77, 0.60), // orange
            SIMD3(0.81, 0.70, 1.00), // purple
            SIMD3(0.50, 0.75, 0.69), // teal
            SIMD3(1.00, 0.74, 0.85), // pink
            SIMD3(0.89, 1.00, 0.65), // lime
            SIMD3(0.78, 0.66, 0.56), // brown
            SIMD3(0.61, 0.70, 0.44), // olive
            SIMD3(0.69, 0.51, 0.61), // plum
        ],
        sunburst: SunburstPalette(
            branchHues: .hashed(saturationScale: 0.55, brightnessScale: 1.12)
        )
    )

    /// Muted natural tones — terracotta, ochre, moss — in the same hue-role
    /// slots as Classic, so each category keeps a recognizable family.
    static let earth = VizPalette(
        id: "earth",
        title: "Earth",
        kinds: earthKinds,
        sunburst: SunburstPalette(branchHues: .table(earthKinds))
    )

    /// Okabe-Ito kinds/categories + viridis age ramp; the branch mode
    /// restricts its hues to the same table.
    static let colorblind = VizPalette(
        id: "colorblind",
        title: "Colorblind-safe",
        kindPalette: okabeItoKinds,
        categoryRoles: [
            "cat-video": 0,      // blue
            "cat-apps": 1,       // vermillion
            "cat-image": 2,      // bluish green
            "cat-code": 3,       // reddish purple
            "cat-archive": 4,    // orange
            "cat-audio": 5,      // sky blue
            "cat-docs": 6,       // yellow
            "cat-data": 7,       // indigo
            "cat-summarized": 8, // teal
            "cat-system": 10,    // sand
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
        ],
        sunburst: SunburstPalette(branchHues: .table(okabeItoKinds))
    )

    // MARK: - Shared role maps and raw tables

    /// Category → kind-table index for every palette that keeps the classic
    /// hue-role ordering (videos in the blue slot, images in the green slot,
    /// and so on).
    private static let classicCategoryRoles: [String: Int] = [
        "cat-video": 0,      // blue
        "cat-apps": 1,       // red
        "cat-image": 2,      // green
        "cat-code": 3,       // magenta
        "cat-docs": 4,       // yellow
        "cat-audio": 5,      // cyan
        "cat-archive": 6,    // orange
        "cat-data": 7,       // purple
        "cat-summarized": 8, // teal
        "cat-system": 11,    // brown
    ]

    /// Age ramp as kind-table indices, cool → hot with age so stale files
    /// glow warm: blue, cyan, lime, yellow, orange, red slots. Shared by
    /// every classic-role palette; the `unknown` bucket appends the neutral.
    private static let classicAgeRoles = [0, 5, 10, 4, 6, 1]

    private static let earthKinds: [SIMD3<Float>] = [
        SIMD3(0.35, 0.49, 0.60), // steel blue
        SIMD3(0.76, 0.33, 0.25), // terracotta
        SIMD3(0.45, 0.58, 0.32), // moss
        SIMD3(0.64, 0.39, 0.53), // berry
        SIMD3(0.85, 0.69, 0.34), // ochre
        SIMD3(0.42, 0.65, 0.63), // agave
        SIMD3(0.80, 0.47, 0.24), // burnt orange
        SIMD3(0.52, 0.44, 0.63), // dusty purple
        SIMD3(0.30, 0.50, 0.44), // pine
        SIMD3(0.78, 0.53, 0.53), // dusty rose
        SIMD3(0.63, 0.66, 0.37), // sage
        SIMD3(0.55, 0.39, 0.26), // saddle brown
        SIMD3(0.45, 0.47, 0.20), // dark olive
        SIMD3(0.50, 0.33, 0.40), // mauve
    ]

    /// Okabe-Ito, extended past the canonical eight with CVD-checked tones.
    private static let okabeItoKinds: [SIMD3<Float>] = [
        SIMD3(0.000, 0.447, 0.698), // blue
        SIMD3(0.835, 0.369, 0.000), // vermillion
        SIMD3(0.000, 0.620, 0.451), // bluish green
        SIMD3(0.800, 0.475, 0.655), // reddish purple
        SIMD3(0.902, 0.624, 0.000), // orange
        SIMD3(0.337, 0.706, 0.914), // sky blue
        SIMD3(0.941, 0.894, 0.259), // yellow
        SIMD3(0.200, 0.133, 0.533), // indigo
        SIMD3(0.267, 0.667, 0.600), // teal
        SIMD3(0.533, 0.133, 0.333), // wine
        SIMD3(0.867, 0.800, 0.467), // sand
        SIMD3(0.600, 0.600, 0.200), // olive
        SIMD3(0.800, 0.400, 0.467), // rose
        SIMD3(0.600, 0.867, 1.000), // pale cyan
    ]

    /// Explicit-everything initializer; the convenience below derives the
    /// category map and age ramp for classic-role palettes.
    private init(
        id: String,
        title: String,
        kindPalette: [SIMD3<Float>],
        categoryRoles: [String: Int],
        ageRamp: [SIMD3<Float>],
        sunburst: SunburstPalette
    ) {
        self.id = id
        self.title = title
        self.kindPalette = kindPalette
        var categories = categoryRoles.mapValues { kindPalette[$0] }
        categories["cat-other"] = FileKindCatalog.otherRGB
        self.categoryRGB = categories
        self.ageRamp = ageRamp
        self.sunburst = sunburst
    }

    /// A palette in the classic hue-role order: categories and the age ramp
    /// derive from the kind table through the shared role maps.
    private init(id: String, title: String, kinds: [SIMD3<Float>], sunburst: SunburstPalette) {
        self.init(
            id: id,
            title: title,
            kindPalette: kinds,
            categoryRoles: Self.classicCategoryRoles,
            ageRamp: Self.classicAgeRoles.map { kinds[$0] } + [FileKindCatalog.otherRGB],
            sunburst: sunburst
        )
    }
}

extension Color {
    /// The SwiftUI color for a palette RGB triple (sRGB components 0…1).
    init(rgb: SIMD3<Float>) {
        self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

/// The two synthetic volume cells the treemap draws (free space, hidden
/// space) and the status bar echoes in its swatches. Neutral greys, so they
/// are already CVD-safe and shared across all palettes — unlike the
/// categorical kind/age hues above.
enum SyntheticSpaceColors {
    nonisolated static let freeSpaceRGB = SIMD3<Float>(0.13, 0.13, 0.16)
    /// A lighter neutral than the near-black free-space cell, so the two
    /// synthetic blocks read as related but distinct quiet areas.
    nonisolated static let hiddenSpaceRGB = SIMD3<Float>(0.30, 0.30, 0.33)
}
