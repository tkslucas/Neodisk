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
//  Every kind table is RANK-ordered: the Types mode hands table[i] to the
//  i-th largest kind. All palettes follow ONE canonical hue-family
//  sequence — green, blue, red, magenta/pink, yellow, orange, purple,
//  cyan/aqua, then the tail — so any prefix spreads across the color wheel,
//  and switching palettes re-skins the map without reshuffling which family
//  each rank, category, or branch gets. Classic, Vivid, and Colorblind
//  derive categories through the shared role map below; Retro and Neon
//  carry terminal-scheme accent sets (warm faded amber-and-olive, and soft
//  neon on a dark canvas) — saturation-punched for area fills via
//  `punched` — whose maps differ only in the two tail categories their
//  schemes lack colors for. Colorblind is the Okabe-Ito
//  qualitative palette (designed to stay distinct under deuteranopia/
//  protanopia/tritanopia) with the viridis ramp for age — perceptually
//  uniform and monotonic in lightness so it still reads in greyscale.
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
        kinds: classicKinds,
        // Branch mode uses the continuous size-midpoint hue wheel — the
        // kind table stays for the Types/Categories modes. The saturation
        // envelope rides above the plain wheel: the resolver's 0.75
        // first-ring saturation reads washed out under the cushion's
        // shading and the flat style's translucent composite.
        sunburst: SunburstPalette(branchHues: .wheel(saturationScale: 1.15, brightnessScale: 1))
    )

    /// The classic hues punched up (saturation and brightness raised in HSB)
    /// — reads especially well under the cushion's shading, which multiplies
    /// every color down.
    static let vivid = VizPalette(
        id: "vivid",
        title: "Vivid",
        kinds: vividKinds,
        // The wheel's saturation envelope pushed up a step beyond Classic's,
        // matching the punched-up kind table.
        sunburst: SunburstPalette(branchHues: .wheel(saturationScale: 1.3, brightnessScale: 1))
    )

    /// Warm faded terminal tones — brick red, olive green, amber, muted
    /// blue-grey. Branch mode quantizes the midpoint wheel into the table,
    /// like a terminal's fixed accent set; categories keep their hue
    /// families through the palette's own role map (the table is
    /// rank-ordered, not role-ordered).
    static let retro = VizPalette(
        id: "retro",
        title: "Retro",
        kindPalette: retroKinds,
        categoryRoles: retroCategoryRoles,
        // Cool → hot in-scheme: blue, aqua, green, yellow, orange, red.
        ageRamp: [
            retroKinds[1],  // bright blue — newest
            retroKinds[7],  // bright aqua
            retroKinds[10], // green
            retroKinds[4],  // bright yellow
            retroKinds[5],  // bright orange
            retroKinds[2],  // bright red — oldest
            FileKindCatalog.otherRGB,
        ],
        sunburst: .quantized(retroKinds)
    )

    /// Soft neon accents against the dark canvas — glowing mint, pink,
    /// lavender, ice blue. Branch mode quantizes the midpoint wheel into
    /// the table, like a terminal's fixed accent set; categories keep
    /// their hue families through the palette's own role map (the table
    /// is rank-ordered, not role-ordered).
    static let neon = VizPalette(
        id: "neon",
        title: "Neon",
        kindPalette: neonKinds,
        categoryRoles: neonCategoryRoles,
        // Cool → hot in-scheme: purple, cyan, green, yellow, orange, red.
        ageRamp: [
            neonKinds[1],  // purple — newest
            neonKinds[7],  // cyan
            neonKinds[9],  // bright green
            neonKinds[4],  // yellow
            neonKinds[5],  // orange
            neonKinds[2],  // red — oldest
            FileKindCatalog.otherRGB,
        ],
        sunburst: .quantized(neonKinds)
    )

    /// Okabe-Ito kinds/categories + viridis age ramp; the branch mode
    /// quantizes the midpoint wheel into the same table, so its colors
    /// stay CVD-safe (the continuous wheel would not be).
    static let colorblind = VizPalette(
        id: "colorblind",
        title: "Colorblind-safe",
        kindPalette: okabeItoKinds,
        // The table follows the canonical rank sequence, so the shared role
        // map lands every category on the same Okabe-Ito hues as always.
        categoryRoles: classicCategoryRoles,
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
        sunburst: .quantized(okabeItoKinds)
    )

    // MARK: - Shared role maps and raw tables

    /// Category → kind-table index under the canonical rank sequence
    /// (green, blue, red, magenta, yellow, orange, purple, cyan, …): videos
    /// in the blue slot, images in the green slot, and so on. Shared by
    /// Classic, Vivid, and Colorblind; Retro and Neon match it on slots
    /// 0–7 and differ only where their schemes run out of matching hues.
    private static let classicCategoryRoles: [String: Int] = [
        "cat-image": 0,      // green
        "cat-video": 1,      // blue
        "cat-apps": 2,       // red
        "cat-code": 3,       // magenta
        "cat-docs": 4,       // yellow
        "cat-archive": 5,    // orange
        "cat-data": 6,       // purple
        "cat-audio": 7,      // cyan
        "cat-summarized": 8, // teal
        "cat-system": 11,    // brown
    ]

    /// Age ramp as kind-table indices, cool → hot with age so stale files
    /// glow warm: blue, cyan, lime, yellow, orange, red slots. Shared by
    /// every classic-role palette; the `unknown` bucket appends the neutral.
    private static let classicAgeRoles = [1, 7, 10, 4, 5, 2]

    private static let classicKinds: [SIMD3<Float>] = [
        SIMD3(0.30, 0.75, 0.32), // green
        SIMD3(0.31, 0.48, 0.95), // blue
        SIMD3(0.90, 0.28, 0.26), // red
        SIMD3(0.83, 0.29, 0.83), // magenta
        SIMD3(0.95, 0.78, 0.20), // yellow
        SIMD3(0.95, 0.52, 0.19), // orange
        SIMD3(0.56, 0.36, 0.90), // purple
        SIMD3(0.25, 0.78, 0.82), // cyan
        SIMD3(0.20, 0.60, 0.50), // teal
        SIMD3(0.94, 0.45, 0.65), // pink
        SIMD3(0.62, 0.80, 0.24), // lime
        SIMD3(0.62, 0.44, 0.28), // brown
        SIMD3(0.42, 0.56, 0.14), // olive
        SIMD3(0.55, 0.27, 0.42), // plum
    ]

    private static let vividKinds: [SIMD3<Float>] = [
        SIMD3(0.21, 0.84, 0.24), // green
        SIMD3(0.16, 0.38, 1.00), // blue
        SIMD3(1.00, 0.14, 0.12), // red
        SIMD3(0.93, 0.18, 0.93), // magenta
        SIMD3(1.00, 0.78, 0.02), // yellow
        SIMD3(1.00, 0.44, 0.01), // orange
        SIMD3(0.53, 0.25, 1.00), // purple
        SIMD3(0.12, 0.86, 0.92), // cyan
        SIMD3(0.11, 0.67, 0.53), // teal
        SIMD3(1.00, 0.34, 0.61), // pink
        SIMD3(0.65, 0.90, 0.12), // lime
        SIMD3(0.69, 0.44, 0.22), // brown
        SIMD3(0.43, 0.63, 0.04), // olive
        SIMD3(0.62, 0.22, 0.43), // plum
    ]

    /// The retro accents punched up for the map (see `punched`); everything
    /// palette-side — kinds, categories, age ramp, quantized branch table —
    /// derives from this, so the scheme stays internally consistent.
    private static let retroKinds = punched(retroAccents, saturationPower: 0.55)

    /// The verbatim 14-accent set of the classic warm retro terminal scheme
    /// (7 bright accents + 7 muted counterparts), rank-ordered for hue
    /// diversity: every prefix mixes the scheme's hue families, so the top
    /// size ranks — and positionally colored branches — never land three
    /// warm accents in a row. Categories map through `retroCategoryRoles`.
    private static let retroAccents: [SIMD3<Float>] = [
        SIMD3(0.722, 0.733, 0.149), // bright green  #b8bb26
        SIMD3(0.514, 0.647, 0.596), // bright blue   #83a598
        SIMD3(0.984, 0.286, 0.204), // bright red    #fb4934
        SIMD3(0.827, 0.525, 0.608), // bright purple #d3869b
        SIMD3(0.980, 0.741, 0.184), // bright yellow #fabd2f
        SIMD3(0.996, 0.502, 0.098), // bright orange #fe8019
        SIMD3(0.694, 0.384, 0.525), // purple        #b16286
        SIMD3(0.557, 0.753, 0.486), // bright aqua   #8ec07c
        SIMD3(0.800, 0.141, 0.114), // red           #cc241d
        SIMD3(0.271, 0.522, 0.533), // blue          #458588
        SIMD3(0.596, 0.592, 0.102), // green         #98971a
        SIMD3(0.843, 0.600, 0.129), // yellow        #d79921
        SIMD3(0.408, 0.616, 0.416), // aqua          #689d6a
        SIMD3(0.839, 0.365, 0.055), // orange        #d65d0e
    ]

    private static let retroCategoryRoles: [String: Int] = [
        "cat-video": 1,       // bright blue
        "cat-apps": 2,        // bright red
        "cat-image": 0,       // bright green
        "cat-code": 3,        // bright purple
        "cat-docs": 4,        // bright yellow
        "cat-audio": 7,       // bright aqua
        "cat-archive": 5,     // bright orange
        "cat-data": 6,        // purple
        "cat-summarized": 12, // aqua
        "cat-system": 13,     // orange
    ]

    /// The neon accents punched up for the map (see `punched`), like
    /// `retroKinds` above.
    private static let neonKinds = punched(neonAccents, saturationPower: 0.55)

    /// The verbatim ANSI accent set of the well-known dark vampire theme
    /// (8 base accents + 6 brights), rank-ordered for hue diversity — the
    /// base accents interleaved so every prefix spreads across the wheel,
    /// the brights in the rank-only tail. Categories map through
    /// `neonCategoryRoles`; its ANSI blue is the signature purple.
    private static let neonAccents: [SIMD3<Float>] = [
        SIMD3(0.314, 0.980, 0.482), // green          #50fa7b
        SIMD3(0.741, 0.576, 0.976), // purple (ANSI blue) #bd93f9
        SIMD3(1.000, 0.333, 0.333), // red            #ff5555
        SIMD3(1.000, 0.475, 0.776), // pink           #ff79c6
        SIMD3(0.945, 0.980, 0.549), // yellow         #f1fa8c
        SIMD3(1.000, 0.722, 0.424), // orange         #ffb86c
        SIMD3(0.384, 0.447, 0.643), // comment blue   #6272a4
        SIMD3(0.545, 0.914, 0.992), // cyan           #8be9fd
        SIMD3(1.000, 0.573, 0.875), // bright magenta #ff92df
        SIMD3(0.412, 1.000, 0.580), // bright green   #69ff94
        SIMD3(0.839, 0.675, 1.000), // bright purple  #d6acff
        SIMD3(0.643, 1.000, 1.000), // bright cyan    #a4ffff
        SIMD3(1.000, 1.000, 0.647), // bright yellow  #ffffa5
        SIMD3(1.000, 0.431, 0.431), // bright red     #ff6e6e
    ]

    private static let neonCategoryRoles: [String: Int] = [
        "cat-image": 0,       // green
        "cat-video": 1,       // purple (the scheme's blue)
        "cat-apps": 2,        // red
        "cat-code": 3,        // pink
        "cat-docs": 4,        // yellow
        "cat-archive": 5,     // orange
        "cat-data": 6,        // comment blue
        "cat-audio": 7,       // cyan
        "cat-summarized": 11, // bright cyan
        "cat-system": 10,     // bright purple
    ]

    /// A scheme's accent table punched up for the map: saturation raised on
    /// a power curve (s^power, 0 < power < 1), so the muted accents gain
    /// the most and the already-vivid ones barely move — hue and brightness
    /// stay verbatim, keeping the scheme recognizable. The raw terminal
    /// accents read too pastel as area fills: colors that carry on a strip
    /// of text wash out spread over a treemap cell.
    private static func punched(
        _ entries: [SIMD3<Float>],
        saturationPower: Double
    ) -> [SIMD3<Float>] {
        entries.map { entry in
            let (hue, saturation, brightness) = SunburstColorResolver.hsb(fromRGB: entry)
            return SunburstColorResolver.rgb(from: SunburstColorComponents(
                hue: hue,
                saturation: pow(saturation, saturationPower),
                brightness: brightness
            ))
        }
    }

    /// Okabe-Ito, extended past the canonical eight with CVD-checked tones,
    /// in the canonical rank sequence (bluish green in the green slot,
    /// indigo in the purple slot, sand in the brown slot, …).
    private static let okabeItoKinds: [SIMD3<Float>] = [
        SIMD3(0.000, 0.620, 0.451), // bluish green
        SIMD3(0.000, 0.447, 0.698), // blue
        SIMD3(0.835, 0.369, 0.000), // vermillion
        SIMD3(0.800, 0.475, 0.655), // reddish purple
        SIMD3(0.941, 0.894, 0.259), // yellow
        SIMD3(0.902, 0.624, 0.000), // orange
        SIMD3(0.200, 0.133, 0.533), // indigo
        SIMD3(0.337, 0.706, 0.914), // sky blue
        SIMD3(0.267, 0.667, 0.600), // teal
        SIMD3(0.533, 0.133, 0.333), // wine
        SIMD3(0.600, 0.600, 0.200), // olive
        SIMD3(0.867, 0.800, 0.467), // sand
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
