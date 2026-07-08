import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct AgeBucketTests {
    private let reference = Date(timeIntervalSince1970: 1_750_000_000)

    private func date(daysAgo: Double) -> Date {
        reference.addingTimeInterval(-daysAgo * 86_400)
    }

    @Test func bucketsByAgeAgainstReferenceDate() {
        #expect(AgeBucket.bucket(for: date(daysAgo: 0), reference: reference) == .day)
        #expect(AgeBucket.bucket(for: date(daysAgo: 0.9), reference: reference) == .day)
        #expect(AgeBucket.bucket(for: date(daysAgo: 1.1), reference: reference) == .week)
        #expect(AgeBucket.bucket(for: date(daysAgo: 6.9), reference: reference) == .week)
        #expect(AgeBucket.bucket(for: date(daysAgo: 7.1), reference: reference) == .month)
        #expect(AgeBucket.bucket(for: date(daysAgo: 29), reference: reference) == .month)
        #expect(AgeBucket.bucket(for: date(daysAgo: 31), reference: reference) == .quarter)
        #expect(AgeBucket.bucket(for: date(daysAgo: 90), reference: reference) == .quarter)
        #expect(AgeBucket.bucket(for: date(daysAgo: 92), reference: reference) == .year)
        #expect(AgeBucket.bucket(for: date(daysAgo: 364), reference: reference) == .year)
        #expect(AgeBucket.bucket(for: date(daysAgo: 366), reference: reference) == .older)
        #expect(AgeBucket.bucket(for: date(daysAgo: 3_650), reference: reference) == .older)
    }

    @Test func missingDateIsUnknownAndFutureDateIsToday() {
        #expect(AgeBucket.bucket(for: nil, reference: reference) == .unknown)
        // Clock skew / restored backups: future mtimes count as today.
        #expect(AgeBucket.bucket(for: date(daysAgo: -5), reference: reference) == .day)
    }
}

@Suite struct AgeCatalogTests {
    private let reference = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func buildCountsCountableNodesPerBucketInChronologicalOrder() {
        let children = [
            makeTestFileNode(id: "/scan/new.mov", name: "new.mov", size: 100,
                             lastModified: reference.addingTimeInterval(-3_600)),
            makeTestFileNode(id: "/scan/old.jpg", name: "old.jpg", size: 40,
                             lastModified: reference.addingTimeInterval(-500 * 86_400)),
            makeTestFileNode(id: "/scan/older.txt", name: "older.txt", size: 20,
                             lastModified: reference.addingTimeInterval(-800 * 86_400)),
            makeTestFileNode(id: "/scan/undated.bin", name: "undated.bin", size: 7),
        ]
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: children)
        let store = FileTreeStore(
            root: root,
            childrenByID: ["/scan": FileTreeStore.sortedChildren(children)]
        )

        let catalog = AgeCatalog.build(from: store, referenceDate: reference)

        // Plain directories don't count; empty buckets are omitted; order is
        // newest-first (bucket order, not size order).
        #expect(catalog.stats.map(\.bucket) == [.day, .older, .unknown])
        let day = catalog.stats[0]
        #expect(day.fileCount == 1)
        #expect(day.totalAllocatedSize == 100)
        let older = catalog.stats[1]
        #expect(older.fileCount == 2)
        #expect(older.totalAllocatedSize == 60)
        let unknown = catalog.stats[2]
        #expect(unknown.fileCount == 1)
        #expect(unknown.totalAllocatedSize == 7)
    }
}

@Suite struct TreemapAgeColoringTests {
    private let reference = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeStore() -> FileTreeStore {
        let children = [
            makeTestFileNode(id: "/scan/new.mov", name: "new.mov", size: 3_000,
                             lastModified: reference.addingTimeInterval(-3_600)),
            makeTestFileNode(id: "/scan/old.jpg", name: "old.jpg", size: 2_000,
                             lastModified: reference.addingTimeInterval(-500 * 86_400)),
            makeTestFileNode(id: "/scan/undated.bin", name: "undated.bin", size: 1_000),
        ]
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: children)
        return FileTreeStore(
            root: root,
            childrenByID: ["/scan": FileTreeStore.sortedChildren(children)]
        )
    }

    @Test func ageModeColorsLeavesByBucket() throws {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 400, height: 300),
            catalog: FileKindCatalog.build(from: store),
            colorMode: .age(referenceDate: reference)
        )

        func rgb(_ id: String) throws -> SIMD3<Float> {
            try #require(scene.cells.first { $0.nodeID == id }).rgb
        }

        #expect(try rgb("/scan/new.mov") == AgeBucket.day.rgb)
        #expect(try rgb("/scan/old.jpg") == AgeBucket.older.rgb)
        #expect(try rgb("/scan/undated.bin") == AgeBucket.unknown.rgb)
    }

    @Test func ageBucketHighlightDimsOtherBuckets() throws {
        let store = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 400, height: 300),
            catalog: FileKindCatalog.build(from: store),
            colorMode: .age(referenceDate: reference),
            highlight: .ageBucket(.older)
        )

        func rgb(_ id: String) throws -> SIMD3<Float> {
            try #require(scene.cells.first { $0.nodeID == id }).rgb
        }

        #expect(try rgb("/scan/old.jpg") == AgeBucket.older.rgb)
        #expect(try rgb("/scan/new.mov") == TreemapScene.dimmedRGB(AgeBucket.day.rgb))
        #expect(try rgb("/scan/undated.bin") == TreemapScene.dimmedRGB(AgeBucket.unknown.rgb))
    }

    @Test func nodeSetHighlightKeepsListedNodesLit() throws {
        let store = makeStore()
        let catalog = FileKindCatalog.build(from: store)
        let scene = TreemapScene.build(
            store: store, rootID: "/scan",
            size: CGSize(width: 400, height: 300),
            catalog: catalog,
            highlight: .nodes(["/scan/new.mov", "/scan/undated.bin"])
        )

        func rgb(_ id: String) throws -> SIMD3<Float> {
            try #require(scene.cells.first { $0.nodeID == id }).rgb
        }

        #expect(try rgb("/scan/new.mov") == catalog.rgb(for: store.node(id: "/scan/new.mov")!))
        #expect(try rgb("/scan/old.jpg")
            == TreemapScene.dimmedRGB(catalog.rgb(for: store.node(id: "/scan/old.jpg")!)))
    }
}
