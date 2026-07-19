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
//  Classic, Vivid, Retro, and Neon share one hue-role ordering (index 0 is
//  the blue slot, 1 the red slot, …), so category colors and the age ramp
//  derive from the kind table through the shared role maps below — switching
//  between them never changes what a color means, only how it looks. Retro
//  and Neon are terminal-colorscheme moods (warm faded amber-and-olive, and
//  soft neon accents on a dark canvas) with hues restricted per branch like
//  a terminal's fixed accent set. Colorblind uses the Okabe-Ito qualitative
//  palette (designed to stay distinct under deuteranopia/protanopia/
//  tritanopia) with its own role map, and the viridis ramp for age —
//  perceptually uniform and monotonic in lightness so it still reads in
//  greyscale.
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
    static let all: [VizPalette] = [.standard, .vivid, .retro, .neon, .colorblind]

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

    /// Warm faded terminal tones — brick red, olive green, amber, muted
    /// blue-grey — in the classic role slots. Branch hues restrict to the
    /// table, like a terminal's fixed accent set.
    static let retro = VizPalette(
        id: "retro",
        title: "Retro",
        kinds: retroKinds,
        sunburst: SunburstPalette(branchHues: .table(retroKinds))
    )

    /// Soft neon accents against the dark canvas — glowing mint, pink,
    /// lavender, ice blue — in the classic role slots. Branch hues restrict
    /// to the table, like a terminal's fixed accent set.
    static let neon = VizPalette(
        id: "neon",
        title: "Neon",
        kinds: neonKinds,
        sunburst: SunburstPalette(branchHues: .table(neonKinds))
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

    /// The verbatim 14-accent set of the classic warm retro terminal scheme
    /// (7 bright accents + 7 muted counterparts). Bright accents take the
    /// category-bearing slots; the muted counterparts fill the rank-only
    /// tail, so a busy Types legend stays in-scheme.
    private static let retroKinds: [SIMD3<Float>] = [
        SIMD3(0.514, 0.647, 0.596), // bright blue   #83a598
        SIMD3(0.984, 0.286, 0.204), // bright red    #fb4934
        SIMD3(0.722, 0.733, 0.149), // bright green  #b8bb26
        SIMD3(0.827, 0.525, 0.608), // bright purple #d3869b
        SIMD3(0.980, 0.741, 0.184), // bright yellow #fabd2f
        SIMD3(0.557, 0.753, 0.486), // bright aqua   #8ec07c
        SIMD3(0.996, 0.502, 0.098), // bright orange #fe8019
        SIMD3(0.694, 0.384, 0.525), // purple        #b16286
        SIMD3(0.408, 0.616, 0.416), // aqua          #689d6a
        SIMD3(0.843, 0.600, 0.129), // yellow        #d79921
        SIMD3(0.596, 0.592, 0.102), // green         #98971a
        SIMD3(0.839, 0.365, 0.055), // orange        #d65d0e
        SIMD3(0.271, 0.522, 0.533), // blue          #458588
        SIMD3(0.800, 0.141, 0.114), // red           #cc241d
    ]

    /// The verbatim ANSI accent set of the well-known dark vampire theme
    /// (8 base accents + 6 brights). Base accents take the category-bearing
    /// slots — its ANSI blue is the signature purple — and the brights fill
    /// the rank-only tail.
    private static let neonKinds: [SIMD3<Float>] = [
        SIMD3(0.741, 0.576, 0.976), // purple (ANSI blue) #bd93f9
        SIMD3(1.000, 0.333, 0.333), // red            #ff5555
        SIMD3(0.314, 0.980, 0.482), // green          #50fa7b
        SIMD3(1.000, 0.475, 0.776), // pink           #ff79c6
        SIMD3(0.945, 0.980, 0.549), // yellow         #f1fa8c
        SIMD3(0.545, 0.914, 0.992), // cyan           #8be9fd
        SIMD3(1.000, 0.722, 0.424), // orange         #ffb86c
        SIMD3(0.384, 0.447, 0.643), // comment blue   #6272a4
        SIMD3(0.643, 1.000, 1.000), // bright cyan    #a4ffff
        SIMD3(1.000, 0.573, 0.875), // bright magenta #ff92df
        SIMD3(0.412, 1.000, 0.580), // bright green   #69ff94
        SIMD3(0.839, 0.675, 1.000), // bright purple  #d6acff
        SIMD3(1.000, 1.000, 0.647), // bright yellow  #ffffa5
        SIMD3(1.000, 0.431, 0.431), // bright red     #ff6e6e
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
