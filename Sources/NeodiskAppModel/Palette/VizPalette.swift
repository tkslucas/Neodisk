// Every raw visualization color table lives here. Kind tables are rank-ordered and follow one hue-family
// sequence, so switching palettes re-skins the map without reshuffling which family each rank gets.

import Foundation
import SunburstCore

package struct VizPalette: Sendable, Equatable, Identifiable {
    /// Stable identifier, persisted in the "vizPalette" preference.
    package let id: String
    /// Display name for the Settings picker; localized at the point of use.
    package let title: String
    /// Rank-ordered: the largest kind gets the first color. Beyond this many kinds, cells fall back to grey.
    package let kindPalette: [SIMD3<Float>]
    /// Fixed colors for the Categories kind mode, keyed by category id — a
    /// category keeps its color regardless of size rank.
    package let categoryRGB: [String: SIMD3<Float>]
    /// By position: the kind slots no built-in category holds first, then the rest (repeats only past that).
    package let customCategoryRGB: [SIMD3<Float>]
    /// Age-bucket colors, indexed by `AgeBucket.rawValue`.
    package let ageRamp: [SIMD3<Float>]
    /// How SunburstCore's branch-hue resolver draws under this palette.
    package let sunburst: SunburstPalette

    /// A category's color under these rules: its fixed color, or for a
    /// user category the custom slot its position picks.
    package func categoryRGB(forID id: String, rules: FileCategoryRules) -> SIMD3<Float> {
        if let rgb = categoryRGB[id] { return rgb }
        guard let index = rules.customColorIndex(forID: id), !customCategoryRGB.isEmpty else {
            return FileKindCatalog.otherRGB
        }
        return customCategoryRGB[index % customCategoryRGB.count]
    }

    package func ageRGB(_ bucket: AgeBucket) -> SIMD3<Float> {
        ageRamp.indices.contains(bucket.rawValue) ? ageRamp[bucket.rawValue] : FileKindCatalog.otherRGB
    }

    // MARK: - Registry

    /// Every selectable palette, in the order the Settings picker lists them.
    package static let all: [VizPalette] = [.standard, .vivid, .graphite, .retro, .neon, .colorblind]

    /// The palette persisted under `id`, or the default for unknown ids
    /// (never fails: a stale preference falls back gracefully).
    package static func named(_ id: String) -> VizPalette {
        all.first { $0.id == id } ?? .standard
    }

    package static let standard = VizPalette(
        id: "standard",
        title: "Classic",
        kinds: classicKinds,
        // Saturation is boosted above the plain wheel: 0.75 first-ring saturation reads washed out under the
        // cushion shading and the flat style's translucent composite.
        sunburst: SunburstPalette(branchHues: .wheel(saturationScale: 1.15, brightnessScale: 1))
    )

    /// The classic hues with raised saturation and brightness; holds up under the cushion's darkening shading.
    package static let vivid = VizPalette(
        id: "vivid",
        title: "Vivid",
        kinds: vividKinds,
        // The wheel's saturation envelope pushed up a step beyond Classic's,
        // matching the punched-up kind table.
        sunburst: SunburstPalette(branchHues: .wheel(saturationScale: 1.3, brightnessScale: 1))
    )

    /// Monochrome: depth of blue is the only signal (biggest kind, branch and oldest age draw deepest).
    /// The ramp is monotonic in lightness so every mode also reads in greyscale.
    package static let graphite = VizPalette(
        id: "graphite",
        title: "Graphite",
        kindPalette: graphiteKinds,
        categoryRoles: classicCategoryRoles,
        ageRamp: [
            SIMD3(0.831, 0.847, 0.863), // light grey — newest
            SIMD3(0.678, 0.722, 0.769),
            SIMD3(0.514, 0.600, 0.686),
            SIMD3(0.357, 0.482, 0.616),
            SIMD3(0.204, 0.376, 0.569),
            SIMD3(0.059, 0.286, 0.510), // deep blue — oldest
            FileKindCatalog.otherRGB,
        ],
        sunburst: .ramp(graphiteBranchRamp)
    )

    /// Eight even steps from deep blue (largest branch) to light grey.
    private static let graphiteBranchRamp: [SIMD3<Float>] = [
        SIMD3(0.059, 0.286, 0.510), // deep blue — largest
        SIMD3(0.169, 0.366, 0.560),
        SIMD3(0.280, 0.446, 0.611),
        SIMD3(0.390, 0.527, 0.661),
        SIMD3(0.500, 0.607, 0.712),
        SIMD3(0.610, 0.687, 0.762),
        SIMD3(0.721, 0.767, 0.813),
        SIMD3(0.831, 0.847, 0.863), // light grey — smallest
    ]

    /// Warm faded terminal tones. Branch mode quantizes the wheel into the table; categories use the
    /// palette's own role map because the table is rank-ordered, not role-ordered.
    package static let retro = VizPalette(
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

    /// Soft neon accents on the dark canvas. Branch mode quantizes the wheel into the table; categories use
    /// the palette's own role map because the table is rank-ordered, not role-ordered.
    package static let neon = VizPalette(
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

    /// Okabe-Ito plus viridis age. Branch mode quantizes into the same table so it stays colorblind-safe,
    /// which the continuous wheel would not.
    package static let colorblind = VizPalette(
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

    /// Category to kind-table index under the canonical rank sequence. Retro and Neon match it on slots 0-7
    /// and differ only where their schemes run out of matching hues.
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
        "cat-3d": 9,         // pink
        "cat-games": 10,     // lime
        "cat-system": 11,    // brown
        "cat-backups": 13,   // plum
    ]

    /// Cool to hot with age so stale files glow warm; the `unknown` bucket appends the neutral.
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

    /// 14 steps over the same grey-blue span as the age and branch ramps; the biggest kind draws deepest.
    private static let graphiteKinds: [SIMD3<Float>] = {
        let deep = SIMD3<Float>(0.059, 0.286, 0.510)
        let light = SIMD3<Float>(0.831, 0.847, 0.863)
        return (0..<14).map { deep + (light - deep) * (Float($0) / 13) }
    }()

    /// Everything palette-side derives from these punched accents, so the scheme stays consistent.
    private static let retroKinds = punched(retroAccents, saturationPower: 0.55)

    /// The retro scheme's 14 accents, rank-ordered so every prefix mixes hue families and the top ranks
    /// never get three warm accents in a row.
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
        "cat-backups": 8,     // red
        "cat-3d": 9,          // blue
        "cat-games": 10,      // green
        "cat-summarized": 12, // aqua
        "cat-system": 13,     // orange
    ]

    /// The neon accents punched up for the map (see `punched`), like
    /// `retroKinds` above.
    private static let neonKinds = punched(neonAccents, saturationPower: 0.55)

    /// A dark theme's ANSI accents, base ones interleaved so every prefix spreads across the wheel and
    /// brights in the tail. Its ANSI blue is the signature purple.
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
        "cat-3d": 8,          // bright magenta
        "cat-games": 9,       // bright green
        "cat-summarized": 11, // bright cyan
        "cat-system": 10,     // bright purple
        "cat-backups": 13,    // bright red
    ]

    /// Raises saturation on a power curve so muted accents gain most, keeping hue and brightness. Raw
    /// terminal accents look too pastel as area fills.
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

    /// Okabe-Ito extended past eight with colorblind-checked tones, in the canonical rank sequence.
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
        let taken = Set(categoryRoles.values)
        self.customCategoryRGB = kindPalette.indices
            .sorted { (taken.contains($0) ? 1 : 0, $0) < (taken.contains($1) ? 1 : 0, $1) }
            .map { kindPalette[$0] }
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

/// Free and hidden space cells. Neutral greys, already colorblind-safe, so shared by all palettes.
package enum SyntheticSpaceColors {
    package nonisolated static let freeSpaceRGB = SIMD3<Float>(0.13, 0.13, 0.16)
    /// A lighter neutral than the near-black free-space cell, so the two
    /// synthetic blocks read as related but distinct quiet areas.
    package nonisolated static let hiddenSpaceRGB = SIMD3<Float>(0.30, 0.30, 0.33)
}
