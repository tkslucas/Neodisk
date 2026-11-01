// The app-side styling pass over a FileTreeStore layout: branch, kind and age fills, and highlight dimming.

import Foundation
import NeodiskKit
import SunburstCore
import Testing
@testable import NeodiskAppModel

@Suite struct SunburstStylingTests {
    private let reference = Date(timeIntervalSince1970: 1_750_000_000)

    /// /root → fresh (1h old), stale (2y old), undated, app (opaque package), docs/ → inner.
    private func makeStore() -> FileTreeStore {
        let inner = makeTestFileNode(id: "/root/docs/inner", name: "inner", size: 20)
        let docs = makeTestDirectoryNode(id: "/root/docs", name: "docs", children: [inner])
        let bundled = makeTestFileNode(id: "/root/app/bin", name: "bin", size: 10)
        let app = makeTestDirectoryNode(id: "/root/app", name: "app", children: [bundled], isPackage: true)
        let children = [
            makeTestFileNode(id: "/root/fresh", name: "fresh", size: 40, lastModified: reference.addingTimeInterval(-3_600)),
            makeTestFileNode(id: "/root/stale", name: "stale", size: 30, lastModified: reference.addingTimeInterval(-800 * 86_400)),
            makeTestFileNode(id: "/root/undated", name: "undated", size: 25),
            docs,
            app,
        ]
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        return FileTreeStore(root: root, childrenByID: [root.id: children, docs.id: [inner]])
    }

    private func fills(_ segments: [SunburstSegment]) -> [String: SIMD3<Float>] {
        var result: [String: SIMD3<Float>] = [:]
        for segment in segments {
            if let id = segment.nodeID, let rgb = segment.fillRGB {
                result[id] = rgb
            }
        }
        return result
    }

    @Test func branchModeResolvesEveryNodeTokenAndLeavesSyntheticArcsUnfilled() throws {
        let store = makeStore()
        let segments = SunburstLayout.segments(in: store, rootID: store.rootID, depthLimit: 3, freeSpaceBytes: 100)
        #expect(segments.contains { $0.nodeID == "/root/docs/inner" })
        for segment in segments {
            if segment.nodeID == nil {
                #expect(segment.fillRGB == nil)
            } else {
                #expect(segment.fillRGB == SunburstColorResolver.rgb(for: segment.colorToken, palette: VizPalette.standard.sunburst))
            }
        }
        let free = try #require(segments.last)
        #expect(free.isFreeSpace)
        #expect(!free.label.isEmpty)
    }

    @Test func branchModeIgnoresHighlights() {
        let store = makeStore()
        let plain = SunburstLayout.segments(in: store, rootID: store.rootID, depthLimit: 2)
        let highlighted = SunburstLayout.segments(
            in: store, rootID: store.rootID, depthLimit: 2,
            style: SunburstColorStyle(highlight: .nodes(["/root/fresh"]))
        )
        #expect(fills(plain) == fills(highlighted))
    }

    @Test func kindModeGraysFoldersAndColorsLeafLikeItemsByKind() throws {
        let store = makeStore()
        let segments = SunburstLayout.segments(
            in: store, rootID: store.rootID, depthLimit: 2,
            style: SunburstColorStyle(mode: .kind)
        )
        let rgb = fills(segments)
        #expect(rgb["/root/docs"] == FileKindCatalog.directoryRGB)
        // An empty catalog maps every kind to the shared "other" neutral; a package is leaf-like.
        #expect(rgb["/root/fresh"] == FileKindCatalog.otherRGB)
        #expect(rgb["/root/app"] == FileKindCatalog.otherRGB)
        #expect(rgb["/root/docs/inner"] == FileKindCatalog.otherRGB)
    }

    @Test func kindHighlightDimsEverythingElse() {
        let store = makeStore()
        let segments = SunburstLayout.segments(
            in: store, rootID: store.rootID, depthLimit: 1,
            style: SunburstColorStyle(mode: .kind, highlight: .nodes(["/root/fresh"]))
        )
        let rgb = fills(segments)
        #expect(rgb["/root/fresh"] == FileKindCatalog.otherRGB)
        #expect(rgb["/root/stale"] == TreemapScene.dimmedRGB(FileKindCatalog.otherRGB))
        #expect(rgb["/root/docs"] == TreemapScene.dimmedRGB(FileKindCatalog.directoryRGB))
    }

    @Test func ageModeRampsFilesAgainstTheScanDate() {
        let store = makeStore()
        let palette = VizPalette.standard
        let segments = SunburstLayout.segments(
            in: store, rootID: store.rootID, depthLimit: 1,
            style: SunburstColorStyle(mode: .age(referenceDate: reference))
        )
        let rgb = fills(segments)
        #expect(rgb["/root/fresh"] == palette.ageRGB(.day))
        #expect(rgb["/root/stale"] == palette.ageRGB(.older))
        #expect(rgb["/root/undated"] == palette.ageRGB(.unknown))
        #expect(rgb["/root/docs"] == FileKindCatalog.directoryRGB)
    }

    @Test func ageBucketHighlightKeepsOnlyThatBucketBright() {
        let store = makeStore()
        let palette = VizPalette.standard
        let segments = SunburstLayout.segments(
            in: store, rootID: store.rootID, depthLimit: 1,
            style: SunburstColorStyle(mode: .age(referenceDate: reference), highlight: .ageBucket(.day))
        )
        let rgb = fills(segments)
        #expect(rgb["/root/fresh"] == palette.ageRGB(.day))
        #expect(rgb["/root/stale"] == TreemapScene.dimmedRGB(palette.ageRGB(.older)))
        // Folders never match an age bucket.
        #expect(rgb["/root/docs"] == TreemapScene.dimmedRGB(FileKindCatalog.directoryRGB))
    }

    @Test func restylingKeepsGeometryAndChangesOnlyFills() {
        let store = makeStore()
        let branch = SunburstLayout.segments(in: store, rootID: store.rootID, depthLimit: 2)
        let kind = SunburstLayout.styled(branch, style: SunburstColorStyle(mode: .kind), in: store)
        #expect(kind.count == branch.count)
        for (lhs, rhs) in zip(branch, kind) {
            #expect(lhs.id == rhs.id && lhs.startAngle == rhs.startAngle && lhs.outerRadius == rhs.outerRadius)
        }
        #expect(fills(kind) != fills(branch))
    }

    @Test func styledSkipsSegmentsWhoseNodeLeftTheStore() {
        let store = makeStore()
        let ghost = SunburstSegment(
            id: "/gone", nodeID: "/gone", label: "gone",
            startAngle: 0, endAngle: 1, innerRadius: 0.3, outerRadius: 0.4, depth: 0,
            colorToken: SunburstColorToken(midpoint: 0.5, depth: 1, role: .normal),
            fillRGB: SIMD3<Float>(1, 0, 0), totalSize: 1, isAggregate: false
        )
        let styled = SunburstLayout.styled([ghost], style: SunburstColorStyle(), in: store)
        #expect(styled.first?.fillRGB == nil)
    }

    @Test func otherPalettesFeedTheBranchWheel() {
        let store = makeStore()
        let standard = SunburstLayout.segments(in: store, rootID: store.rootID, depthLimit: 1)
        let neon = SunburstLayout.segments(
            in: store, rootID: store.rootID, depthLimit: 1,
            style: SunburstColorStyle(palette: .neon)
        )
        #expect(fills(standard)["/root/docs"] != fills(neon)["/root/docs"])
    }

    @Test func styleEqualityTracksModeHighlightPaletteAndCatalogBuild() {
        let catalog = FileKindCatalog(stats: [])
        let base = SunburstColorStyle(mode: .kind, catalog: catalog)
        #expect(base == SunburstColorStyle(mode: .kind, catalog: catalog))
        // Every rebuild may reassign colors, so a fresh catalog is a different style.
        #expect(base != SunburstColorStyle(mode: .kind, catalog: FileKindCatalog(stats: [])))
        #expect(base != SunburstColorStyle(mode: .branch, catalog: catalog))
        #expect(base != SunburstColorStyle(mode: .kind, catalog: catalog, highlight: .kind("txt")))
        #expect(base != SunburstColorStyle(mode: .kind, catalog: catalog, palette: .graphite))
        #expect(SunburstColorStyle.Mode.age(referenceDate: reference) != .age(referenceDate: .distantPast))
    }

    @Test func recordFolderTestFollowsPackageSplicing() throws {
        let store = makeStore()
        let docs = try #require(store.node(id: "/root/docs"))
        let app = try #require(store.node(id: "/root/app"))
        let fresh = try #require(store.node(id: "/root/fresh"))
        #expect(docs.isSunburstFolder(in: store))
        #expect(!app.isSunburstFolder(in: store))
        #expect(!fresh.isSunburstFolder(in: store))
    }
}
