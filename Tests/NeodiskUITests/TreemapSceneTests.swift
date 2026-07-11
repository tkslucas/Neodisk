//
//  TreemapSceneTests.swift
//  Neodisk
//

import CoreGraphics
import Foundation
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskUI

@Suite struct TreemapSceneTests {
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

    @Test func sceneCoversEveryFile() {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 400, height: 300),
            catalog: .empty
        )

        let cellIDs = Set(scene.cells.map(\.nodeID))
        #expect(cellIDs.contains("/scan/a.mov"))
        #expect(cellIDs.contains("/scan/b.jpg"))
        #expect(cellIDs.contains("/scan/sub/c.txt"))

        let totalArea = scene.cells.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(totalArea - 400 * 300) < 1)
    }

    @Test func hitTestFindsCellUnderPoint() throws {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 400, height: 300),
            catalog: .empty
        )

        let cell = try #require(scene.cells.first { $0.nodeID == "/scan/a.mov" })
        let center = CGPoint(x: cell.rect.midX, y: cell.rect.midY)
        #expect(scene.cell(at: center)?.nodeID == "/scan/a.mov")
    }

    @Test func rectForNodeMatchesRenderedLeafCell() throws {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 400, height: 300),
            catalog: .empty
        )

        let cell = try #require(scene.cells.first { $0.nodeID == "/scan/sub/c.txt" })
        let rect = try #require(scene.rect(forNodeID: "/scan/sub/c.txt", in: store))
        #expect(abs(rect.minX - cell.rect.minX) < 0.001)
        #expect(abs(rect.minY - cell.rect.minY) < 0.001)
        #expect(abs(rect.width - cell.rect.width) < 0.001)
        #expect(abs(rect.height - cell.rect.height) < 0.001)
    }

    @Test func zoomedSceneUsesSubtreeOnly() {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan/sub",
            size: CGSize(width: 200, height: 200),
            catalog: .empty
        )
        #expect(scene.cells.count == 1)
        #expect(scene.cells.first?.nodeID == "/scan/sub/c.txt")
        #expect(scene.cells.first.map { $0.rect.width * $0.rect.height } ?? 0 > 39_000)
    }

    @Test func tinyChildrenMergeIntoAggregateCell() throws {
        let rootURL = URL(filePath: "/agg", directoryHint: .isDirectory)
        func file(_ name: String, _ size: Int64) -> FileNodeRecord {
            FileNodeRecord(
                id: "/agg/\(name)", url: rootURL.appending(path: name), name: name,
                isDirectory: false, isSymbolicLink: false,
                allocatedSize: size, logicalSize: size, descendantFileCount: 0,
                lastModified: nil, isPackage: false, isAccessible: true,
                isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
            )
        }
        // One dominant file plus many files that would each occupy well under
        // minChildCellArea in a 400×300 map.
        var children = [file("big.bin", 1_000_000)]
        for index in 0..<50 {
            children.append(file("tiny\(index).txt", 300))
        }
        let root = FileNodeRecord.directory(
            id: "/agg", url: rootURL, name: "agg", children: children,
            lastModified: nil, isPackage: false, isAccessible: true
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: ["/agg": FileTreeStore.sortedChildren(children)]
        )

        let scene = TreemapScene.build(
            store: store, rootID: "/agg",
            size: CGSize(width: 400, height: 300),
            catalog: .empty
        )

        // 50 tiny files collapse into one aggregate cell.
        #expect(scene.cells.count == 2)
        let aggregateCell = try #require(scene.cells.first { $0.aggregate != nil })
        #expect(aggregateCell.nodeID == "/agg")
        #expect(aggregateCell.aggregate?.itemCount == 50)
        #expect(aggregateCell.aggregate?.totalSize == 15_000)

        // Coverage is preserved: cells still tile the full canvas.
        let totalArea = scene.cells.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(totalArea - 400 * 300) < 1)

        // A merged node's rect resolves to the aggregate cell.
        let mergedRect = try #require(scene.rect(forNodeID: "/agg/tiny5.txt", in: store))
        #expect(abs(mergedRect.minX - aggregateCell.rect.minX) < 0.001)
        #expect(abs(mergedRect.width - aggregateCell.rect.width) < 0.001)
    }

    @Test func zoomedViewportPrunesAndStaysConsistent() throws {
        let store = makeStore()
        let size = CGSize(width: 400, height: 300)

        // Zoom 4x anchored at the far corner, then verify geometry agreement
        // between rendered cells and rect(forNodeID:).
        let viewport = TreemapViewport.identity
            .zoomed(by: 4, anchor: CGPoint(x: 380, y: 280), viewSize: size)
        #expect(viewport.scale == 4)

        let scene = TreemapScene.build(
            store: store, rootID: "/scan", size: size,
            catalog: .empty, viewport: viewport
        )

        let bounds = CGRect(origin: .zero, size: size)
        #expect(!scene.cells.isEmpty)
        for cell in scene.cells {
            #expect(cell.rect.intersects(bounds))
        }
        // Visible area is fully covered by (possibly clipped) cells.
        let coveredArea = scene.cells.reduce(0.0) {
            let clipped = $1.rect.intersection(bounds)
            return $0 + Double(clipped.width * clipped.height)
        }
        #expect(abs(coveredArea - Double(size.width * size.height)) < 1)

        for cell in scene.cells where cell.aggregate == nil {
            let rect = try #require(scene.rect(forNodeID: cell.nodeID, in: store))
            #expect(abs(rect.minX - cell.rect.minX) < 0.001)
            #expect(abs(rect.width - cell.rect.width) < 0.001)
        }
    }

    @Test func viewportZoomKeepsAnchorStationaryAndClamps() {
        let size = CGSize(width: 400, height: 300)
        let anchor = CGPoint(x: 100, y: 150)

        let zoomed = TreemapViewport.identity.zoomed(by: 2, anchor: anchor, viewSize: size)
        // The virtual point that was under the anchor stays under it.
        let before = CGPoint(x: anchor.x, y: anchor.y)
        let after = CGPoint(
            x: (before.x) * 2 - zoomed.origin.x,
            y: (before.y) * 2 - zoomed.origin.y
        )
        #expect(abs(after.x - anchor.x) < 0.001)
        #expect(abs(after.y - anchor.y) < 0.001)

        // Zooming below 1 clamps to identity.
        let out = zoomed.zoomed(by: 0.1, anchor: anchor, viewSize: size)
        #expect(out.scale == 1)
        #expect(out.origin == .zero)

        // Panning never exposes past the canvas edge.
        let panned = zoomed.panned(by: CGSize(width: 10_000, height: 10_000), viewSize: size)
        #expect(panned.origin == .zero)
    }

    @Test func rendererHandlesEveryChunkBoundaryCellCount() {
        // Regression: ceil-divided parallel chunks trapped (invalid range)
        // for cell counts just above the core count, e.g. 10 cells on 8
        // cores. Sweep small counts to cover every boundary on any machine.
        let rootURL = URL(filePath: "/chunk", directoryHint: .isDirectory)
        for count in 1...40 {
            var children: [FileNodeRecord] = []
            for index in 0..<count {
                let name = "f\(index).bin"
                children.append(FileNodeRecord(
                    id: "/chunk/\(name)", url: rootURL.appending(path: name), name: name,
                    isDirectory: false, isSymbolicLink: false,
                    allocatedSize: Int64(1000 + index), logicalSize: Int64(1000 + index),
                    descendantFileCount: 0, lastModified: nil, isPackage: false,
                    isAccessible: true, isSelfAccessible: true,
                    isSynthetic: false, isAutoSummarized: false
                ))
            }
            let sorted = FileTreeStore.sortedChildren(children)
            let root = FileNodeRecord.directory(
                id: "/chunk", url: rootURL, name: "chunk", children: sorted,
                lastModified: nil, isPackage: false, isAccessible: true,
                childrenAreSorted: true
            )
            let store = FileTreeStore(root: root, childrenByID: ["/chunk": sorted])
            let scene = TreemapScene.build(
                store: store, rootID: "/chunk",
                size: CGSize(width: 300, height: 200), catalog: .empty
            )
            #expect(CushionTreemapRenderer.render(cells: scene.cells, bounds: scene.renderBounds, scale: 2) != nil, "count \(count)")
        }
    }

    @Test func freeSpaceNodeJoinsRootLayoutAndStaysConsistent() throws {
        let store = makeStore()
        let size = CGSize(width: 400, height: 300)
        let scene = TreemapScene.build(
            store: store, rootID: "/scan", size: size,
            catalog: .empty, freeSpaceBytes: 1_000
        )

        // Free space owns half the canvas (tree total is also 1000).
        let freeCell = try #require(scene.cells.first { $0.isFreeSpace })
        let freeArea = Double(freeCell.rect.width * freeCell.rect.height)
        #expect(abs(freeArea - 400 * 300 / 2) < 1)

        // Full coverage preserved, and rect(forNodeID:) agrees with the
        // shifted sibling layout.
        let totalArea = scene.cells.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(totalArea - 400 * 300) < 1)
        let movCell = try #require(scene.cells.first { $0.nodeID == "/scan/a.mov" })
        let movRect = try #require(scene.rect(forNodeID: "/scan/a.mov", in: store))
        #expect(abs(movRect.minX - movCell.rect.minX) < 0.001)
        #expect(abs(movRect.width - movCell.rect.width) < 0.001)

        // Off by default.
        let plain = TreemapScene.build(store: store, rootID: "/scan", size: size, catalog: .empty)
        #expect(!plain.cells.contains { $0.isFreeSpace })
    }

    @Test func kindHighlightKeepsMatchesAndDimsRest() throws {
        let store = makeStore()
        let size = CGSize(width: 400, height: 300)
        let catalog = FileKindCatalog.build(from: store)

        let plain = TreemapScene.build(
            store: store, rootID: "/scan", size: size, catalog: catalog
        )
        let highlighted = TreemapScene.build(
            store: store, rootID: "/scan", size: size, catalog: catalog,
            highlight: .kind("mov")
        )

        func rgb(_ scene: TreemapScene, _ id: String) throws -> SIMD3<Float> {
            try #require(scene.cells.first { $0.nodeID == id }).rgb
        }

        // Matching cell keeps its full kind color.
        #expect(try rgb(highlighted, "/scan/a.mov") == catalog.rgb(forKindID: "mov"))
        // Non-matching cells dim by the documented blend.
        let jpgBase = catalog.rgb(forKindID: "jpg")
        #expect(try rgb(highlighted, "/scan/b.jpg") == TreemapScene.dimmedRGB(jpgBase))
        #expect(try rgb(highlighted, "/scan/b.jpg") != jpgBase)
        #expect(try rgb(highlighted, "/scan/sub/c.txt")
            == TreemapScene.dimmedRGB(catalog.rgb(forKindID: "txt")))

        // No highlight: colors identical to today's rendering.
        #expect(try rgb(plain, "/scan/a.mov") == catalog.rgb(forKindID: "mov"))
        #expect(try rgb(plain, "/scan/b.jpg") == jpgBase)
    }

    @Test func kindHighlightAggregateMatchesOnDirectTail() throws {
        // Same fixture as tinyChildrenMergeIntoAggregateCell: one big .bin
        // plus 50 tiny .txt files that merge into an aggregate cell.
        let rootURL = URL(filePath: "/agg", directoryHint: .isDirectory)
        func file(_ name: String, _ size: Int64) -> FileNodeRecord {
            FileNodeRecord(
                id: "/agg/\(name)", url: rootURL.appending(path: name), name: name,
                isDirectory: false, isSymbolicLink: false,
                allocatedSize: size, logicalSize: size, descendantFileCount: 0,
                lastModified: nil, isPackage: false, isAccessible: true,
                isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
            )
        }
        var children = [file("big.bin", 1_000_000)]
        for index in 0..<50 {
            children.append(file("tiny\(index).txt", 300))
        }
        let root = FileNodeRecord.directory(
            id: "/agg", url: rootURL, name: "agg", children: children,
            lastModified: nil, isPackage: false, isAccessible: true
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: ["/agg": FileTreeStore.sortedChildren(children)]
        )
        let size = CGSize(width: 400, height: 300)
        let catalog = FileKindCatalog.build(from: store)

        func aggregateRGB(highlight: String?) throws -> SIMD3<Float> {
            let scene = TreemapScene.build(
                store: store, rootID: "/agg", size: size, catalog: catalog,
                highlight: highlight.map { .kind($0) }
            )
            return try #require(scene.cells.first { $0.aggregate != nil }).rgb
        }

        // The merged tail is all .txt: highlighting txt keeps the aggregate
        // lit; highlighting bin dims it; no highlight leaves it as-is.
        #expect(try aggregateRGB(highlight: "txt") == FileKindCatalog.otherRGB)
        #expect(try aggregateRGB(highlight: "bin")
            == TreemapScene.dimmedRGB(FileKindCatalog.otherRGB))
        #expect(try aggregateRGB(highlight: nil) == FileKindCatalog.otherRGB)
    }

    @Test func rendererProducesImageOfExpectedSize() {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 100, height: 80),
            catalog: .empty
        )
        let image = CushionTreemapRenderer.render(cells: scene.cells, bounds: scene.renderBounds, scale: 2)
        #expect(image?.width == 200)
        #expect(image?.height == 160)
    }
}

@Suite struct FileKindCategoryTests {
    private func makeNode(_ name: String, size: Int64 = 100, isPackage: Bool = false, isDirectory: Bool = false) -> FileNodeRecord {
        FileNodeRecord(
            id: "/c/\(name)", url: URL(filePath: "/c/\(name)"), name: name,
            isDirectory: isDirectory, isSymbolicLink: false,
            allocatedSize: size, logicalSize: size, descendantFileCount: 0,
            lastModified: nil, isPackage: isPackage, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
    }

    @Test func extensionsMapToExpectedCategories() {
        #expect(FileKindClassifier.kindID(for: makeNode("a.mkv"), mode: .categories) == "cat-video")
        #expect(FileKindClassifier.kindID(for: makeNode("b.heic"), mode: .categories) == "cat-image")
        #expect(FileKindClassifier.kindID(for: makeNode("c.flac"), mode: .categories) == "cat-audio")
        #expect(FileKindClassifier.kindID(for: makeNode("d.pdf"), mode: .categories) == "cat-docs")
        #expect(FileKindClassifier.kindID(for: makeNode("e.dmg"), mode: .categories) == "cat-archive")
        #expect(FileKindClassifier.kindID(for: makeNode("f.swift"), mode: .categories) == "cat-code")
        #expect(FileKindClassifier.kindID(for: makeNode("g.parquet"), mode: .categories) == "cat-data")
        #expect(FileKindClassifier.kindID(for: makeNode("h.unknownext"), mode: .categories) == "cat-other")
        #expect(FileKindClassifier.kindID(
            for: makeNode("Word.app", isPackage: true, isDirectory: true),
            mode: .categories
        ) == "cat-apps")
    }

    @Test func packagesCountInKindStatistics() {
        let appNode = makeNode("Word.app", size: 5_000, isPackage: true, isDirectory: true)
        let fileNode = makeNode("movie.mp4", size: 2_000)
        let plainDir = makeNode("sub", size: 0, isDirectory: true)

        let rootURL = URL(filePath: "/c", directoryHint: .isDirectory)
        let children = FileTreeStore.sortedChildren([appNode, fileNode])
        let root = FileNodeRecord.directory(
            id: "/c", url: rootURL, name: "c", children: children,
            lastModified: nil, isPackage: false, isAccessible: true, childrenAreSorted: true
        )
        let store = FileTreeStore(root: root, childrenByID: ["/c": children])
        #expect(FileKindClassifier.isKindCountable(appNode, in: store))
        #expect(FileKindClassifier.isKindCountable(fileNode, in: store))
        #expect(!FileKindClassifier.isKindCountable(plainDir, in: store))

        let types = FileKindCatalog.build(from: store, mode: .types)
        #expect(types.stats.contains { $0.kind.id == "app" && $0.totalAllocatedSize == 5_000 })

        let categories = FileKindCatalog.build(from: store, mode: .categories)
        #expect(categories.stats.first?.kind.id == "cat-apps")
        #expect(categories.stats.contains { $0.kind.id == "cat-video" })
    }

    /// Once "Show Package Contents" splices a package's children into the
    /// store, the files inside are counted individually and the package
    /// itself no longer is — counting both would double its size.
    @Test func expandedPackagesCountTheirContentsInstead() {
        let binary = FileNodeRecord(
            id: "/c/Word.app/Contents", url: URL(filePath: "/c/Word.app/Contents"), name: "Contents",
            isDirectory: false, isSymbolicLink: false,
            allocatedSize: 5_000, logicalSize: 5_000, descendantFileCount: 0,
            lastModified: nil, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
        let appNode = makeNode("Word.app", size: 5_000, isPackage: true, isDirectory: true)
        let rootURL = URL(filePath: "/c", directoryHint: .isDirectory)
        let root = FileNodeRecord.directory(
            id: "/c", url: rootURL, name: "c", children: [appNode],
            lastModified: nil, isPackage: false, isAccessible: true, childrenAreSorted: true
        )
        let store = FileTreeStore(root: root, childrenByID: [
            "/c": [appNode],
            appNode.id: [binary],
        ])

        #expect(!FileKindClassifier.isKindCountable(appNode, in: store))
        #expect(FileKindClassifier.isKindCountable(binary, in: store))
        // Display identity is unchanged: an expanded package still reads and
        // colors as an app, not as a plain folder.
        #expect(FileKindClassifier.isLeafLike(appNode))
        #expect(FileKindClassifier.kindID(for: appNode, mode: .categories) == "cat-apps")

        let categories = FileKindCatalog.build(from: store, mode: .categories)
        let totalCounted = categories.stats.reduce(Int64(0)) { $0 + $1.totalAllocatedSize }
        #expect(totalCounted == 5_000)
    }
}

@Suite struct FileKindStatisticsTests {
    @Test func kindsGroupByExtensionAndRankBySize() {
        let rootURL = URL(filePath: "/k", directoryHint: .isDirectory)
        func file(_ name: String, _ size: Int64) -> FileNodeRecord {
            FileNodeRecord(
                id: "/k/\(name)", url: rootURL.appending(path: name), name: name,
                isDirectory: false, isSymbolicLink: false,
                allocatedSize: size, logicalSize: size, descendantFileCount: 0,
                lastModified: nil, isPackage: false, isAccessible: true,
                isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
            )
        }
        let children = [
            file("a.mov", 1000), file("b.mov", 500),
            file("c.jpg", 700), file("d", 10),
        ]
        let root = FileNodeRecord.directory(
            id: "/k", url: rootURL, name: "k", children: children,
            lastModified: nil, isPackage: false, isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: ["/k": children])

        let catalog = FileKindCatalog.build(from: store)

        #expect(catalog.stats.count == 3)
        #expect(catalog.stats[0].kind.id == "mov")
        #expect(catalog.stats[0].totalAllocatedSize == 1500)
        #expect(catalog.stats[0].fileCount == 2)
        #expect(catalog.stats[1].kind.id == "jpg")
        #expect(catalog.stats[2].kind.id == "no-extension")

        // Top kinds get distinct palette colors.
        #expect(catalog.rgb(forKindID: "mov") == FileKindCatalog.palette[0])
        #expect(catalog.rgb(forKindID: "jpg") == FileKindCatalog.palette[1])
        // Unknown kinds fall back to the neutral color.
        #expect(catalog.rgb(forKindID: "zzz-unknown") == FileKindCatalog.otherRGB)
    }
}
