import Foundation
import Testing
import NeodiskKit
import SunburstCore
@testable import NeodiskUI

/// The palette registry and its wiring through the kind catalog.
@MainActor
@Suite struct VizPaletteTests {
    @Test func testRegistryResolvesEveryIDAndFallsBackToStandard() {
        for palette in VizPalette.all {
            #expect(VizPalette.named(palette.id) == palette)
        }
        // A stale or unknown persisted id must never leave the app blank.
        #expect(VizPalette.named("no-such-palette") == .standard)
        #expect(Set(VizPalette.all.map(\.id)).count == VizPalette.all.count)
    }

    @Test func testEveryPaletteCoversEveryKindSlotCategoryAndAgeBucket() {
        // A color for every rank the kind mode colors, for every fixed
        // category, and for every age bucket — in every selectable palette —
        // so nothing silently falls back to grey when the picker switches.
        let categoryKeys = Set(VizPalette.standard.categoryRGB.keys)
        for palette in VizPalette.all {
            #expect(palette.kindPalette.count == FileKindCatalog.coloredKindLimit)
            #expect(Set(palette.categoryRGB.keys) == categoryKeys)
            #expect(palette.ageRamp.count == AgeBucket.allCases.count)
        }
    }

    @Test func testClassicRolePalettesShareColorMeaning() {
        // Classic and Vivid keep one hue-role order: each category maps to
        // the same kind-table slot, so switching between them changes the
        // look, never what a color means.
        for palette in [VizPalette.vivid] {
            for (category, rgb) in VizPalette.standard.categoryRGB where category != "cat-other" {
                let index = VizPalette.standard.kindPalette.firstIndex(of: rgb)
                let paletteIndex = palette.kindPalette.firstIndex(of: palette.categoryRGB[category]!)
                #expect(index == paletteIndex, "role mismatch for \(category) in \(palette.id)")
            }
            // Age ramp reuses the kind table at the same role slots.
            #expect(palette.ageRGB(.day) == palette.kindPalette[0])
            #expect(palette.ageRGB(.older) == palette.kindPalette[1])
            #expect(palette.ageRGB(.unknown) == FileKindCatalog.otherRGB)
        }
    }

    @Test func testSchemePalettesStayInsideTheirAccentTables() {
        // Retro and Neon are verbatim terminal-scheme accent sets with their
        // own role maps: every category color and every dated age-ramp entry
        // must be a table entry — nothing hand-invented off-scheme — and the
        // table entries must be pairwise distinct so rank and positional
        // assignment never hand two kinds or branches the same color.
        for palette in [VizPalette.retro, .neon] {
            let table = palette.kindPalette
            #expect(Set(table.map { "\($0)" }).count == table.count, palette.id == "retro" ? "duplicate retro entry" : "duplicate neon entry")
            for (category, rgb) in palette.categoryRGB where category != "cat-other" {
                #expect(table.contains(rgb), "off-scheme category color for \(category) in \(palette.id)")
            }
            for bucket in AgeBucket.allCases where bucket != .unknown {
                #expect(table.contains(palette.ageRGB(bucket)), "off-scheme age color in \(palette.id)")
            }
            #expect(palette.ageRGB(.unknown) == FileKindCatalog.otherRGB)
        }
    }

    @Test func testColorblindPaletteActuallyDiffersFromStandard() {
        #expect(VizPalette.colorblind != VizPalette.standard)
        // The age ramp is the biggest change (rainbow → viridis): every dated
        // bucket must move.
        for bucket in AgeBucket.allCases where bucket != .unknown {
            #expect(VizPalette.colorblind.ageRGB(bucket) != VizPalette.standard.ageRGB(bucket))
        }
    }

    @Test func testCatalogBakesTheSelectedPaletteIntoKindColors() {
        let png = makeTestFileNode(id: "/r/a.png", name: "a.png", size: 100)
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [png])
        let store = FileTreeStore(root: root, childrenByID: ["/r": [png]])

        let standard = FileKindCatalog.build(from: store, mode: .categories, palette: .standard)
        let colorblind = FileKindCatalog.build(from: store, mode: .categories, palette: .colorblind)

        // Images are the first (only) category here; the baked color must come
        // from whichever palette built the catalog.
        #expect(standard.rgb(for: png) == VizPalette.standard.categoryRGB["cat-image"])
        #expect(colorblind.rgb(for: png) == VizPalette.colorblind.categoryRGB["cat-image"])
        #expect(standard.rgb(for: png) != colorblind.rgb(for: png))
    }

    @Test func testTableBranchHuesAssignByPositionNotHash() {
        // With real branch context, a table palette hands the i-th scan-root
        // branch the i-th table entry — the rank-diverse prefix — instead of
        // a hash pick that can land neighboring branches in one hue cluster.
        // Depth and jitter may move saturation/brightness, never the hue.
        let table = VizPalette.retro.kindPalette
        for index in 0..<3 {
            let token = SunburstColorToken(
                branchID: "/scan/branch-\(index)",
                localID: "/scan/branch-\(index)",
                branchIndex: index,
                branchCount: 3,
                siblingIndex: 0,
                siblingCount: 1,
                depth: 0,
                role: .normal
            )
            let components = SunburstColorResolver.components(
                for: token, palette: VizPalette.retro.sunburst
            )
            #expect(
                abs(components.hue - Self.hue(of: table[index])) < 0.001,
                "branch \(index) did not take table entry \(index)"
            )
        }
    }

    @Test func testColorBranchPositionsMatchRootChildOrder() {
        let a = makeTestDirectoryNode(id: "/r/a", name: "a", children: [])
        let b = makeTestDirectoryNode(id: "/r/b", name: "b", children: [])
        let c = makeTestDirectoryNode(id: "/r/c", name: "c", children: [])
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [a, b, c])
        let store = FileTreeStore(root: root, childrenByID: ["/r": [a, b, c]])

        let positions = SunburstLayout.colorBranchPositions(in: store)
        #expect(positions.count == 3)
        #expect(positions["/r/a"]?.index == 0)
        #expect(positions["/r/b"]?.index == 1)
        #expect(positions["/r/c"]?.index == 2)
        #expect(positions["/r/b"]?.count == 3)
    }

    private static func hue(of rgb: SIMD3<Float>) -> Double {
        let r = Double(rgb.x), g = Double(rgb.y), b = Double(rgb.z)
        let maxC = Swift.max(r, g, b), minC = Swift.min(r, g, b)
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        var hue: Double
        if maxC == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        return hue < 0 ? hue + 1 : hue
    }

    @Test func testColorblindToggleMigratesToPalettePickerOnce() {
        let suiteName = "VizPaletteTests-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Old toggle on, no palette chosen yet → carried over.
        defaults.set(true, forKey: "useColorblindPalette")
        #expect(AppPreferences(defaults: defaults).vizPalette == .colorblind)

        // An explicit later choice wins over the old toggle.
        defaults.set(VizPalette.vivid.id, forKey: "vizPalette")
        #expect(AppPreferences(defaults: defaults).vizPalette == .vivid)
    }
}
