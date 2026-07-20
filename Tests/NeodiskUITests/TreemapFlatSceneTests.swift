//
//  TreemapFlatSceneTests.swift
//  Neodisk
//
//  Flat scene layout: folder container cells with
//  nested children, deepest-cell hit-testing over the overlapping cells,
//  and the selection-rect math mirroring the nested insets.
//

import CoreGraphics
import Foundation
import SunburstCore
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskUI

@Suite struct TreemapFlatSceneTests {
    private func makeStore() -> FileTreeStore {
        let rootURL = URL(filePath: "/scan", directoryHint: .isDirectory)
        let fileA = FileNodeRecord(
            id: "/scan/a.mov", url: rootURL.appending(path: "a.mov"), name: "a.mov",
            isDirectory: false, isSymbolicLink: false,
            allocatedSize: 600, logicalSize: 600, descendantFileCount: 0,
            lastModified: nil, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
        let fileB = FileNodeRecord(
            id: "/scan/b.jpg", url: rootURL.appending(path: "b.jpg"), name: "b.jpg",
            isDirectory: false, isSymbolicLink: false,
            allocatedSize: 300, logicalSize: 300, descendantFileCount: 0,
            lastModified: nil, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
        let fileC = FileNodeRecord(
            id: "/scan/sub/c.txt", url: rootURL.appending(path: "sub/c.txt"), name: "c.txt",
            isDirectory: false, isSymbolicLink: false,
            allocatedSize: 100, logicalSize: 100, descendantFileCount: 0,
            lastModified: nil, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
        let sub = FileNodeRecord.directory(
            id: "/scan/sub", url: rootURL.appending(path: "sub", directoryHint: .isDirectory),
            name: "sub", children: [fileC], lastModified: nil,
            isPackage: false, isAccessible: true
        )
        let root = FileNodeRecord.directory(
            id: "/scan", url: rootURL, name: "scan",
            children: [fileA, fileB, sub], lastModified: nil,
            isPackage: false, isAccessible: true
        )
        return FileTreeStore(
            root: root,
            childrenByID: [
                "/scan": [fileA, fileB, sub],
                "/scan/sub": [fileC],
            ]
        )
    }

    /// The flat treemap's branch-mode desaturation, mirrored for expected
    /// colors (TreemapScene.resolvedRGB).
    private func desaturated(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        return rgb + (gray - rgb) * TreemapScene.flatBranchDesaturation
    }

    private func buildFlat(size: CGSize = CGSize(width: 400, height: 300)) -> TreemapScene {
        TreemapScene.build(
            store: makeStore(), rootID: "/scan", style: .flat,
            size: size, catalog: .empty
        )
    }

    @Test func flatEmitsContainerWithNestedChild() throws {
        let scene = buildFlat()

        let container = try #require(scene.cells.first { $0.nodeID == "/scan/sub" })
        #expect(container.isContainer)
        #expect(container.isDirectory)

        // The child cell lays out inside the container's content region
        // (inset frame below the header strip).
        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let content = try #require(TreemapScene.flatContentBounds(of: container.rect))
        #expect(content.insetBy(dx: -0.001, dy: -0.001).contains(child.rect))

        // Container emitted before its child so the flat renderer's serial
        // pass draws parents under descendants.
        let containerIndex = try #require(scene.cells.firstIndex { $0.nodeID == "/scan/sub" })
        let childIndex = try #require(scene.cells.firstIndex { $0.nodeID == "/scan/sub/c.txt" })
        #expect(containerIndex < childIndex)

        // The container carries a header label; files keep their labels.
        let header = try #require(scene.labels.first { $0.id == "/scan/sub" })
        #expect(header.isHeader)
    }

    @Test func flatFilesLabelOnlyGenuinelyBigTiles() throws {
        // At 300×200 the nested c.txt tile falls under the shared file
        // gates, so it stays quiet; the dominant a.mov tile clears them.
        let scene = buildFlat(size: CGSize(width: 300, height: 200))

        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        #expect(child.rect.width * child.rect.height < TreemapScene.labelMinCellArea)
        #expect(!scene.labels.contains { $0.id == "/scan/sub/c.txt" })

        let big = try #require(scene.cells.first { $0.nodeID == "/scan/a.mov" })
        #expect(big.rect.width * big.rect.height >= TreemapScene.labelMinCellArea)
        #expect(scene.labels.contains { $0.id == "/scan/a.mov" })
    }

    @Test func flatHeaderLabelSurvivesViewportClipping() throws {
        // Pan the container almost fully off the left edge: the sliver of
        // header strip still visible emits its name candidate, clamped into
        // the visible bounds. (The view may still drop it if no useful
        // truncation fits — the scene's contract is just the candidate.)
        let identity = buildFlat()
        let container = try #require(identity.cells.first { $0.nodeID == "/scan/sub" })

        let scene = TreemapScene.build(
            store: makeStore(), rootID: "/scan", style: .flat,
            size: CGSize(width: 400, height: 300), catalog: .empty,
            viewport: TreemapViewport(
                scale: 1,
                origin: CGPoint(x: container.rect.maxX - 8, y: 0)
            )
        )
        let header = try #require(scene.labels.first { $0.id == "/scan/sub" && $0.isHeader })
        #expect(header.rect.minX >= 0)
        #expect(header.rect.width < 24)
    }

    @Test func flatHitTestPrefersDeepestCell() throws {
        let scene = buildFlat()

        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let childCenter = CGPoint(x: child.rect.midX, y: child.rect.midY)
        #expect(scene.cell(at: childCenter)?.nodeID == "/scan/sub/c.txt")

        // A point in the container's header strip hits the container itself.
        let container = try #require(scene.cells.first { $0.nodeID == "/scan/sub" })
        let headerPoint = CGPoint(
            x: container.rect.midX,
            y: container.rect.minY + TreemapScene.flatHeaderHeight / 2
        )
        #expect(scene.cell(at: headerPoint)?.nodeID == "/scan/sub")
        #expect(scene.cell(at: headerPoint)?.isContainer == true)
    }

    @Test func flatRectForNodeMatchesRenderedCells() throws {
        let scene = buildFlat()
        let store = makeStore()

        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let childRect = try #require(scene.rect(forNodeID: "/scan/sub/c.txt", in: store))
        #expect(abs(childRect.minX - child.rect.minX) < 0.001)
        #expect(abs(childRect.minY - child.rect.minY) < 0.001)
        #expect(abs(childRect.width - child.rect.width) < 0.001)
        #expect(abs(childRect.height - child.rect.height) < 0.001)

        let container = try #require(scene.cells.first { $0.nodeID == "/scan/sub" })
        let containerRect = try #require(scene.rect(forNodeID: "/scan/sub", in: store))
        #expect(abs(containerRect.minX - container.rect.minX) < 0.001)
        #expect(abs(containerRect.width - container.rect.width) < 0.001)
    }

    @Test func flatTooSmallFolderRendersAsPlainCell() throws {
        // 80×60 leaves /scan/sub (~10% of the area) far below the minimum
        // container size, so it renders undivided — the natural depth cutoff.
        let scene = buildFlat(size: CGSize(width: 80, height: 60))

        let sub = try #require(scene.cells.first { $0.nodeID == "/scan/sub" })
        #expect(!sub.isContainer)
        #expect(!scene.cells.contains { $0.nodeID == "/scan/sub/c.txt" })
        // The tiny undivided folder emits no label candidate: its ~32pt
        // tile sits under the folder pre-filter, where no useful
        // (≥4-character) name could fit anyway.
        #expect(!scene.labels.contains { $0.id == "/scan/sub" })
    }

    @Test func flatDepthCapStopsNestingPastLimit() throws {
        // A chain of single-child directories deeper than the cap, in a map
        // large enough that every rect clears the minimum container size:
        // nesting must stop at flatMaxContainerDepth anyway.
        let rootURL = URL(filePath: "/scan", directoryHint: .isDirectory)
        let levels = TreemapScene.flatMaxContainerDepth + 2
        let ids = (1...levels).map { level in
            "/scan/" + (1...level).map { "d\($0)" }.joined(separator: "/")
        }
        let leaf = FileNodeRecord(
            id: ids[levels - 1] + "/f.bin",
            url: rootURL.appending(path: "f.bin"), name: "f.bin",
            isDirectory: false, isSymbolicLink: false,
            allocatedSize: 1_000, logicalSize: 1_000, descendantFileCount: 0,
            lastModified: nil, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
        var childrenByID: [String: [FileNodeRecord]] = [ids[levels - 1]: [leaf]]
        var node = leaf
        for id in ids.reversed() {
            node = FileNodeRecord.directory(
                id: id, url: rootURL.appending(path: id, directoryHint: .isDirectory),
                name: String(id.split(separator: "/").last!), children: [node],
                lastModified: nil, isPackage: false, isAccessible: true
            )
            childrenByID[id] = childrenByID[id] ?? []
            if let parent = ids.firstIndex(of: id), parent > 0 {
                childrenByID[ids[parent - 1]] = [node]
            }
        }
        let root = FileNodeRecord.directory(
            id: "/scan", url: rootURL, name: "scan", children: [node],
            lastModified: nil, isPackage: false, isAccessible: true
        )
        childrenByID["/scan"] = [node]
        let store = FileTreeStore(root: root, childrenByID: childrenByID)

        let scene = TreemapScene.build(
            store: store, rootID: "/scan", style: .flat,
            size: CGSize(width: 900, height: 900), catalog: .empty
        )

        // d1…d(cap-1) nest; the directory AT the cap renders plain and
        // nothing below it is emitted.
        let capped = try #require(
            scene.cells.first { $0.nodeID == ids[TreemapScene.flatMaxContainerDepth - 1] }
        )
        #expect(!capped.isContainer)
        let lastContainer = try #require(
            scene.cells.first { $0.nodeID == ids[TreemapScene.flatMaxContainerDepth - 2] }
        )
        #expect(lastContainer.isContainer)
        #expect(!scene.cells.contains { $0.nodeID == ids[TreemapScene.flatMaxContainerDepth] })
    }

    @Test func branchColorsMatchSunburstResolver() throws {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan", style: .flat,
            size: CGSize(width: 400, height: 300),
            catalog: .empty, colorMode: .branch
        )

        // The /scan/sub container: its global interval midpoint (sub spans
        // [0.9, 1.0] after a.mov's 0.6 and b.jpg's 0.3) at depth 1, folder
        // role — drawn "translucently" (composited over the raster
        // background) with the flat gray pull.
        let container = try #require(scene.cells.first { $0.nodeID == "/scan/sub" })
        let palette = VizPalette.standard.sunburst
        let subStart = 600.0 / 1000.0 + 300.0 / 1000.0
        let subSpan = 100.0 / 1000.0
        let folderToken = SunburstColorToken(
            midpoint: subStart + subSpan / 2, depth: 1, role: .normal
        )
        let expectedContainer = TreemapScene.flatComposite(
            desaturated(SunburstColorResolver.rgb(for: folderToken, palette: palette)),
            over: TreemapRasterTarget.backgroundRGB
        )
        #expect(container.rgb == expectedContainer)

        // The nested file: it fills sub's interval (same midpoint), one
        // level deeper — the full folder formula (not the sunburst's file
        // gray), composited over the same background as every other cell
        // (never over the container's fill).
        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let fileToken = SunburstColorToken(
            midpoint: subStart + subSpan / 2, depth: 2, role: .normal
        )
        let expectedChild = TreemapScene.flatComposite(
            desaturated(SunburstColorResolver.rgb(for: fileToken, palette: palette)),
            over: TreemapRasterTarget.backgroundRGB
        )
        #expect(child.rgb == expectedChild)

        // A loose file at the scan root goes gray (the sunburst's file
        // treatment): no hue family of its own, and graying it keeps the
        // root's colored folders identifiable. The midpoint still feeds the
        // gray's brightness jitter.
        let rootFile = try #require(scene.cells.first { $0.nodeID == "/scan/a.mov" })
        let rootFileToken = SunburstColorToken(
            midpoint: (600.0 / 1000.0) / 2, depth: 1, role: .file
        )
        let expectedRootFile = TreemapScene.flatComposite(
            SunburstColorResolver.rgb(for: rootFileToken) * TreemapScene.flatRootFileDim,
            over: TreemapRasterTarget.backgroundRGB
        )
        #expect(rootFile.rgb == expectedRootFile)
    }

    @Test func drilledBranchColorsKeepScanRootCoordinate() throws {
        // Rooted at /scan/sub: the color coordinate is still the global
        // scan-root interval (via SunburstLayout.colorCoordinate), and depth
        // is still measured from the SCAN root — drilling in must not
        // recolor or re-brighten the subtree.
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan/sub", style: .flat,
            size: CGSize(width: 400, height: 300),
            catalog: .empty, colorMode: .branch
        )
        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let coordinate = try #require(SunburstLayout.colorCoordinate(for: "/scan/sub", in: store))
        let token = SunburstColorToken(
            midpoint: coordinate.start + coordinate.span / 2, depth: 2, role: .normal
        )
        let expected = TreemapScene.flatComposite(
            desaturated(SunburstColorResolver.rgb(for: token, palette: VizPalette.standard.sunburst)),
            over: TreemapRasterTarget.backgroundRGB
        )
        #expect(child.rgb == expected)
    }

    @Test func cushionSceneEmitsNoContainers() {
        let scene = TreemapScene.build(
            store: makeStore(), rootID: "/scan",
            size: CGSize(width: 400, height: 300), catalog: .empty
        )
        #expect(!scene.cells.contains { $0.isContainer })
        #expect(!scene.labels.contains { $0.isHeader })
    }
}
