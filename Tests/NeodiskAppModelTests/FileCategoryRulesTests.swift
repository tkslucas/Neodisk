import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

/// The built-in categories added for 3D, games and backups, the folder
/// rules, and the user's customization of the table. Rules are passed
/// explicitly: installing them would reclassify for tests running alongside.
@Suite struct FileCategoryRulesTests {
    private func category(_ path: String, rules: FileCategoryRules = .builtIn) -> String {
        let node = makeTestFileNode(id: path, name: (path as NSString).lastPathComponent)
        return FileKindClassifier.kindID(for: node, mode: .categories, rules: rules)
    }

    @Test func newCategoriesTakeTheirExtensions() {
        #expect(category("/p/bracket.STL") == "cat-3d")
        #expect(category("/p/part.step") == "cat-3d")
        #expect(category("/p/scene.blend1") == "cat-3d")
        #expect(category("/p/board.kicad_pcb") == "cat-3d")
        #expect(category("/p/Content.pak") == "cat-games")
        #expect(category("/p/Map.uasset") == "cat-games")
        #expect(category("/p/db.bak") == "cat-backups")
        #expect(category("/p/model.nki") == "cat-audio")
        #expect(category("/p/Outlook.pst") == "cat-docs")
        #expect(category("/p/iPhone.ipsw") == "cat-archive")
    }

    @Test func dockerDiskImageIsNotAPhoto() {
        // Docker's VM disk is "Docker.raw", often tens of gigabytes.
        #expect(category("/Users/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw") == "cat-archive")
    }

    @Test func folderRulesClaimEverythingInside() {
        let steam = "/Users/u/Library/Application Support/Steam/steamapps/common/Game"
        #expect(category("\(steam)/textures.png") == "cat-games")
        #expect(category("\(steam)/engine.dll") == "cat-games")
        #expect(category("/Users/u/Library/Application Support/MobileSync/Backup/0000/3f/3f2a9c1d") == "cat-backups")
        #expect(category("/Users/u/.ollama/models/blobs/sha256-abc") == "cat-data")
        #expect(category("/Users/u/.cache/huggingface/hub/models--x/blobs/9f8e") == "cat-data")
        #expect(category("/Users/u/src/app/.git/objects/ab/cdef") == "cat-code")
    }

    @Test func folderRulesMatchWholeComponentsOnly() {
        #expect(category("/Users/u/my-steamapps/notes.txt") == "cat-docs")
        #expect(category("/Users/u/steamapps") == "cat-other")
        #expect(category("/Users/u/.github/workflow.yml") == "cat-code")
    }

    @Test func outermostFolderRuleWins() {
        #expect(category("/g/steamapps/common/Mod/.git/HEAD") == "cat-games")
    }

    @Test func assigningAnExtensionOverridesTheTable() {
        var customization = FileCategoryCustomization()
        customization.assign(extension: "PSD", to: "cat-3d")
        let rules = FileCategoryRules(customization)
        #expect(category("/p/a.psd", rules: rules) == "cat-3d")
        #expect(rules.isOverridden(extension: "psd"))
        // Everything else keeps the built-in table.
        #expect(category("/p/a.png", rules: rules) == "cat-image")
    }

    @Test func assigningTheBuiltInCategoryDropsTheOverride() {
        var customization = FileCategoryCustomization()
        customization.assign(extension: "psd", to: "cat-docs")
        customization.assign(extension: "psd", to: "cat-image")
        #expect(customization.isEmpty)
    }

    @Test func userCategoriesClassifyNameAndColor() throws {
        var customization = FileCategoryCustomization()
        let added = customization.addCategory(named: "  Lab data ")
        let id = try #require(added)
        customization.assign(extension: "fastq", to: id)
        let rules = FileCategoryRules(customization)

        #expect(FileCategoryRules.isCustomCategoryID(id))
        #expect(category("/p/run1.fastq", rules: rules) == id)
        #expect(rules.customKindsByID[id]?.displayName == "Lab data")
        #expect(rules.assignableCategories.last?.id == id)

        // The first user category takes a slot no built-in category holds.
        for palette in VizPalette.all {
            let rgb = palette.categoryRGB(forID: id, rules: rules)
            #expect(rgb == palette.customCategoryRGB[0])
            #expect(!palette.categoryRGB.values.contains(rgb), "user color taken in \(palette.id)")
        }

        let catalog = FileKindCatalog.build(
            fromAggregated: [PersistedKindStat(kindID: id, size: 10, count: 1)],
            mode: .categories,
            rules: rules
        )
        #expect(catalog.stats.first?.rgb == VizPalette.standard.customCategoryRGB[0])
    }

    @Test func renamingAndRemovingUserCategories() throws {
        var customization = FileCategoryCustomization()
        let added = customization.addCategory(named: "Scans")
        let id = try #require(added)
        customization.assign(extension: "tif", to: id)
        customization.renameCategory(id: id, to: "Paper scans")
        customization.renameCategory(id: id, to: "   ")
        #expect(customization.categories.first?.name == "Paper scans")

        customization.removeCategory(id: id)
        #expect(customization.isEmpty)
        #expect(customization.addCategory(named: " ") == nil)
    }

    @Test func customizationRoundTripsThroughJSON() throws {
        var customization = FileCategoryCustomization()
        let added = customization.addCategory(named: "Lab data")
        let id = try #require(added)
        customization.assign(extension: "fastq", to: id)
        customization.assign(extension: "log", to: "cat-docs")

        #expect(FileCategoryCustomization(json: customization.json) == customization)
        #expect(FileCategoryCustomization().json == "")
        #expect(FileCategoryCustomization(json: "not json").isEmpty)
    }

    @Test func overridesToMissingCategoriesAreDropped() {
        let json = #"{"categories":[],"extensions":{"fastq":"cat-user-gone","log":"cat-docs"}}"#
        #expect(FileCategoryCustomization(json: json).extensions == ["log": "cat-docs"])
    }

    @Test func fingerprintFollowsTheCustomization() {
        var customization = FileCategoryCustomization()
        customization.assign(extension: "log", to: "cat-docs")
        let custom = FileCategoryRules(customization)
        #expect(custom.fingerprint != FileCategoryRules.builtIn.fingerprint)
        #expect(custom.fingerprint == FileCategoryRules(customization).fingerprint)
    }

    @Test func pseudoKindsCannotMove() {
        #expect(FileCategoryRules.isAssignableTypeID("psd"))
        #expect(!FileCategoryRules.isAssignableTypeID("no-extension"))
        #expect(!FileCategoryRules.isAssignableTypeID("symlink"))
    }

    @Test func everyPaletteHasAUserColorPerKindSlot() {
        for palette in VizPalette.all {
            #expect(palette.customCategoryRGB.count == palette.kindPalette.count)
            #expect(Set(palette.customCategoryRGB.map { "\($0)" }) == Set(palette.kindPalette.map { "\($0)" }))
        }
    }
}

/// The byte-level extension reader must agree with Foundation's
/// `pathExtension` on each platform, or the Types grouping would shift.
@Suite struct LowercasedExtensionTests {
    @Test(arguments: [
        "/c/a.MP4", "/c/.gitignore", "/c/.hidden.TXT", "/c/a.", "/c/a..b", "/c/foo.tar.gz",
        "/c/noext", "/c/dir.d/file", "/c/x.app/", "/c/a.b//", "/c/..", "/c/.", "/", "",
        "a.b", "/c/a.b c", "/c/a. b", "/c/a.b ", "/c/x.ÄBC", "/c/a.日本", "/c/a.(1)",
        "/c/report.final draft.PDF",
    ])
    func matchesFoundation(_ path: String) {
        #expect(FileKindClassifier.lowercasedExtension(ofPath: path) == (path as NSString).pathExtension.lowercased())
    }
}
