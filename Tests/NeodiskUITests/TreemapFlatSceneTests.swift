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

    @Test func flatLabelsSmallTilesThatCushionSkips() throws {
        let scene = buildFlat()

        // Every leaf tile in this fixture clears the relaxed flat gates
        // (40×16) — including the nested c.txt, whose tile is smaller than
        // the cushion's 80×22/4000pt² thresholds.
        for id in ["/scan/a.mov", "/scan/b.jpg", "/scan/sub/c.txt"] {
            #expect(scene.labels.contains { $0.id == id }, "missing label for \(id)")
        }

        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        #expect(child.rect.width >= TreemapScene.flatLabelMinCellWidth)
        #expect(child.rect.height >= TreemapScene.flatLabelMinCellHeight)
    }

    @Test func flatHeaderLabelSurvivesViewportClipping() throws {
        // Pan the container almost fully off the left edge: the sliver of
        // header strip still visible must carry the name (truncation absorbs
        // the width), clamped into the visible bounds — no rendered container
        // may be an anonymous box.
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
    }

    @Test func branchColorsMatchSunburstResolver() throws {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan", style: .flat,
            size: CGSize(width: 400, height: 300),
            catalog: .empty, colorMode: .branch
        )

        // The /scan/sub container: its own branch (child of the scan root,
        // depth 0), folder role — the sunburst's first-ring token, drawn
        // "translucently" (composited over the raster background).
        let container = try #require(scene.cells.first { $0.nodeID == "/scan/sub" })
        let folderToken = SunburstColorToken(
            branchID: "/scan/sub", localID: "/scan/sub",
            branchIndex: 0, branchCount: 1, siblingIndex: 0, siblingCount: 1,
            depth: 0, role: .normal
        )
        let expectedContainer = TreemapScene.flatComposite(
            SunburstColorResolver.rgb(for: folderToken),
            over: TreemapRasterTarget.backgroundRGB
        )
        #expect(container.rgb == expectedContainer)

        // The nested file: same branch, one ring deeper — muted branch tint
        // (not the sunburst's file gray), stacked over the container's
        // composited fill.
        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let fileToken = SunburstColorToken(
            branchID: "/scan/sub", localID: "/scan/sub/c.txt",
            branchIndex: 0, branchCount: 1, siblingIndex: 0, siblingCount: 1,
            depth: 1, role: .file
        )
        let expectedChild = TreemapScene.flatComposite(
            SunburstColorResolver.rgb(
                from: SunburstColorResolver.mutedFileComponents(for: fileToken)
            ),
            over: container.rgb
        )
        #expect(child.rgb == expectedChild)
    }

    @Test func drilledBranchColorsKeepScanRootHueFamily() throws {
        // Rooted at /scan/sub: the hue family still derives from the
        // scan-root branch (/scan/sub), depth measured from the drill root —
        // same contract as SunburstColorResolver.branchColor.
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan/sub", style: .flat,
            size: CGSize(width: 400, height: 300),
            catalog: .empty, colorMode: .branch
        )
        let child = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let token = SunburstColorToken(
            branchID: "/scan/sub", localID: "/scan/sub/c.txt",
            branchIndex: 0, branchCount: 1, siblingIndex: 0, siblingCount: 1,
            depth: 0, role: .file
        )
        let expected = TreemapScene.flatComposite(
            SunburstColorResolver.rgb(
                from: SunburstColorResolver.mutedFileComponents(for: token)
            ),
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
