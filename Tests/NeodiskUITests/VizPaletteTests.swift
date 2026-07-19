import Foundation
import Testing
import NeodiskKit
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
        // Classic, Vivid, Retro, and Neon keep one hue-role order: each
        // category maps to the same kind-table slot, so switching between
        // them changes the look, never what a color means.
        for palette in [VizPalette.vivid, .retro, .neon] {
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
