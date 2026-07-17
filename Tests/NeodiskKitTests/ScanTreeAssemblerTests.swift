import Foundation
import Testing
@testable import NeodiskKit

/// Drives `ScanTreeAssembler.legacyAssemble` with hand-built phase-1 state and
/// asserts the full assembled `FileTreeStore` — node order, ids, every record
/// field, topology, aggregate stats, and index lookups. Covers the feature
/// matrix the coordinator can hand phase 2: plain dirs/files, packages,
/// auto-summarized leaves, inaccessible dirs, empty dirs, mount-boundary
/// leaves, hard links, clone families, size ties, and case-insensitive-equal
/// sibling names.
@Suite struct ScanTreeAssemblerTests {
    // MARK: - Fixture builders

    private static func url(_ path: String, isDirectory: Bool = false) -> URL {
        URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    private static func dirMetadata(isReadable: Bool = true, isPackage: Bool = false) -> NodeMetadata {
        NodeMetadata(
            isDirectory: true,
            isPackage: isPackage,
            isSymbolicLink: false,
            logicalSize: 0,
            allocatedSize: 0,
            lastModified: nil,
            isReadable: isReadable,
            volumeUsedCapacity: nil,
            fileIdentity: nil,
            linkCount: 1
        )
    }

    private static func fileRecord(
        _ path: String,
        name: String,
        alloc: Int64,
        logical: Int64? = nil,
        isSymbolicLink: Bool = false,
        identity: FileIdentity? = nil,
        linkCount: UInt64 = 1,
        cloneInfo: CloneInfo? = nil,
        isAccessible: Bool = true
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: path,
            url: url(path),
            name: name,
            isDirectory: false,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: alloc,
            logicalSize: logical ?? alloc,
            descendantFileCount: isSymbolicLink ? 0 : 1,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: linkCount,
            isPackage: false,
            isAccessible: isAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: false,
            cloneInfo: cloneInfo
        )
    }

    /// A directory that reaches phase 2 as an already-materialized leaf record
    /// (package, auto-summary, inaccessible directory, or mount boundary).
    private static func dirLeafRecord(
        _ path: String,
        name: String,
        alloc: Int64,
        logical: Int64? = nil,
        descendantFileCount: Int,
        isPackage: Bool = false,
        isAutoSummarized: Bool = false,
        isAccessible: Bool = true
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: path,
            url: url(path, isDirectory: true),
            name: name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: alloc,
            logicalSize: logical ?? alloc,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            fileIdentity: nil,
            linkCount: 1,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isAccessible,
            isSynthetic: false,
            isAutoSummarized: isAutoSummarized
        )
    }

    private static func traversableScan(
        _ path: String,
        depth: Int,
        directLeaves: [FileNodeRecord] = [],
        isReadable: Bool = true,
        isPackage: Bool = false
    ) -> ScanEngine.CompletedDirScan {
        ScanEngine.CompletedDirScan(
            node: nil,
            directLeafNodes: directLeaves,
            metadata: dirMetadata(isReadable: isReadable, isPackage: isPackage),
            url: url(path, isDirectory: true),
            isTraversable: true,
            depth: depth
        )
    }

    private static func leafScan(_ node: FileNodeRecord, depth: Int) -> ScanEngine.CompletedDirScan {
        ScanEngine.CompletedDirScan(
            node: node,
            metadata: dirMetadata(),
            url: node.url,
            isTraversable: false,
            depth: depth
        )
    }

    /// Runs the fast path (the shipping assembler). The oracle assertions thus
    /// pin the fast path directly against hand-computed expectations.
    private static func assemble(
        completedByKey: [ScanEngine.CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        hardLinkClaims: [HardLinkClaim] = [],
        minimumAllocatedSizeByNodeID: [String: Int64] = [:]
    ) throws -> FileTreeStore {
        try ScanTreeAssembler.assemble(
            completedByKey: completedByKey,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: completedByKey.count,
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID,
            targetURL: url("/root", isDirectory: true),
            diagnostics: nil,
            callbacks: ScanTreeAssembler.Callbacks()
        )
    }

    // MARK: - Full-tree assembly across every node kind

    @Test func assemblesFullTreeAcrossEveryNodeKind() throws {
        let bigBin = Self.fileRecord("/root/big.bin", name: "big.bin", alloc: 1000)
        let link = Self.fileRecord("/root/link", name: "link", alloc: 0, isSymbolicLink: true)
        let aDat = Self.fileRecord("/root/sub/a.dat", name: "a.dat", alloc: 300)
        let bDat = Self.fileRecord("/root/sub/b.dat", name: "b.dat", alloc: 200)

        let appPkg = Self.dirLeafRecord("/root/app.pkg", name: "app.pkg", alloc: 800, descendantFileCount: 5, isPackage: true)
        let gen = Self.dirLeafRecord("/root/gen", name: "gen", alloc: 700, descendantFileCount: 20, isAutoSummarized: true)
        let locked = Self.dirLeafRecord("/root/locked", name: "locked", alloc: 0, descendantFileCount: 0, isAccessible: false)
        let mnt = Self.dirLeafRecord("/root/mnt", name: "mnt", alloc: 50, descendantFileCount: 0)

        let completed: [ScanEngine.CompletedDirScan?] = [
            Self.traversableScan("/root", depth: 0, directLeaves: [bigBin, link]),   // 0
            Self.traversableScan("/root/sub", depth: 1, directLeaves: [aDat, bDat]), // 1
            Self.leafScan(appPkg, depth: 1),                                          // 2
            Self.leafScan(gen, depth: 1),                                             // 3
            Self.leafScan(locked, depth: 1),                                          // 4
            Self.traversableScan("/root/empty", depth: 1),                            // 5
            Self.leafScan(mnt, depth: 1),                                             // 6
        ]
        let children: [[Int]] = [[1, 2, 3, 4, 5, 6], [], [], [], [], [], []]

        let store = try Self.assemble(completedByKey: completed, childrenKeysByKey: children)

        // Preorder node order: root, then children by size desc / name asc,
        // subtrees inline.
        #expect(store.allNodes.map(\.id) == [
            "/root",
            "/root/big.bin",
            "/root/app.pkg",
            "/root/gen",
            "/root/sub",
            "/root/sub/a.dat",
            "/root/sub/b.dat",
            "/root/mnt",
            "/root/empty",
            "/root/link",
            "/root/locked",
        ])

        // Root re-aggregated from its children.
        let root = store.root
        #expect(root.id == "/root")
        #expect(root.name == ScanTarget.displayName(for: Self.url("/root", isDirectory: true)))
        #expect(root.allocatedSize == 3050)
        #expect(root.logicalSize == 3050)
        #expect(root.descendantFileCount == 28)
        #expect(root.isDirectory)
        #expect(!root.isAccessible)          // locked child is inaccessible
        #expect(root.isSelfAccessible)       // root itself is readable

        // Traversable subdirectory aggregated from its two files.
        let sub = try #require(store.node(id: "/root/sub"))
        #expect(sub.allocatedSize == 500)
        #expect(sub.descendantFileCount == 2)
        #expect(sub.isAccessible)

        // Empty traversable directory materializes with zeroed totals.
        let empty = try #require(store.node(id: "/root/empty"))
        #expect(empty.isDirectory)
        #expect(empty.allocatedSize == 0)
        #expect(empty.descendantFileCount == 0)
        #expect(empty.isAccessible)
        #expect(store.storage.childCount(of: try #require(store.storage.index(of: empty.id))) == 0)

        // Keyed leaves pass through untouched.
        #expect(store.node(id: "/root/app.pkg")?.isPackage == true)
        #expect(store.node(id: "/root/gen")?.isAutoSummarized == true)
        #expect(store.node(id: "/root/locked")?.isAccessible == false)
        #expect(store.node(id: "/root/link")?.isSymbolicLink == true)

        // Topology of root's children matches the sorted order.
        let rootIndex = try #require(store.storage.index(of: "/root"))
        let childIDs = store.storage.childIndices(of: rootIndex).map { store.allNodes[Int($0)].id }
        #expect(childIDs == [
            "/root/big.bin", "/root/app.pkg", "/root/gen", "/root/sub",
            "/root/mnt", "/root/empty", "/root/link", "/root/locked",
        ])

        // Aggregate stats.
        let stats = store.aggregateStats
        #expect(stats.fileCount == 28)          // 2 files + package(5) + summary(20) + sub's 2
        #expect(stats.directoryCount == 7)      // root, sub, app.pkg, gen, locked, empty, mnt
        #expect(stats.accessibleItemCount == 9)
        #expect(stats.inaccessibleItemCount == 2) // root (child inaccessible) + locked
        #expect(stats.totalAllocatedSize == 3050)
        #expect(stats.totalLogicalSize == 3050)
    }

    // MARK: - Size ties and case-insensitive-equal sibling names

    @Test func sizeTiesBreakByLocalizedNameOrder() throws {
        // Three equal-size files plus a case-varied pair; localizedStandardCompare
        // fully orders them, so the permutation is deterministic.
        let files = [
            Self.fileRecord("/root/File10", name: "File10", alloc: 100),
            Self.fileRecord("/root/File2", name: "File2", alloc: 100),
            Self.fileRecord("/root/file1", name: "file1", alloc: 100),
            Self.fileRecord("/root/Alpha", name: "Alpha", alloc: 100),
        ]
        let completed: [ScanEngine.CompletedDirScan?] = [
            Self.traversableScan("/root", depth: 0, directLeaves: files),
        ]
        let store = try Self.assemble(completedByKey: completed, childrenKeysByKey: [[]])

        let expected = FileTreeStore.sortedChildren(files).map(\.id)
        let rootIndex = try #require(store.storage.index(of: "/root"))
        let childIDs = store.storage.childIndices(of: rootIndex).map { store.allNodes[Int($0)].id }
        #expect(childIDs == expected)
        #expect(store.root.allocatedSize == 400)
        #expect(store.root.descendantFileCount == 4)
    }

    // MARK: - Hard-link deduplication

    @Test func hardLinkDeduplicationSubtractsDuplicateAllocatedSize() throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let h1 = Self.fileRecord("/root/h1", name: "h1", alloc: 400, identity: identity, linkCount: 2)
        let h2 = Self.fileRecord("/root/h2", name: "h2", alloc: 400, identity: identity, linkCount: 2)
        let completed: [ScanEngine.CompletedDirScan?] = [
            Self.traversableScan("/root", depth: 0, directLeaves: [h1, h2]),
        ]
        let claims = [
            HardLinkClaim(identity: identity, ownerNodeID: h1.id, path: h1.path, allocatedSize: 400),
            HardLinkClaim(identity: identity, ownerNodeID: h2.id, path: h2.path, allocatedSize: 400),
        ]
        let store = try Self.assemble(
            completedByKey: completed,
            childrenKeysByKey: [[]],
            hardLinkClaims: claims
        )

        // First by path keeps full size; the duplicate drops to zero.
        #expect(store.node(id: "/root/h1")?.allocatedSize == 400)
        #expect(store.node(id: "/root/h2")?.allocatedSize == 0)
        // unduplicatedAllocatedSize is preserved for later rebalances.
        #expect(store.node(id: "/root/h2")?.unduplicatedAllocatedSize == 400)
        // Parent total reflects the deduplicated size, children re-sorted.
        #expect(store.root.allocatedSize == 400)
    }

    @Test func hardLinkDeduplicationRespectsMinimumAllocatedSize() throws {
        let identity = FileIdentity(device: 1, inode: 7)
        let h1 = Self.fileRecord("/root/a1", name: "a1", alloc: 400, identity: identity, linkCount: 2)
        let h2 = Self.fileRecord("/root/a2", name: "a2", alloc: 400, identity: identity, linkCount: 2)
        let completed: [ScanEngine.CompletedDirScan?] = [
            Self.traversableScan("/root", depth: 0, directLeaves: [h1, h2]),
        ]
        let claims = [
            HardLinkClaim(identity: identity, ownerNodeID: h1.id, path: h1.path, allocatedSize: 400),
            HardLinkClaim(identity: identity, ownerNodeID: h2.id, path: h2.path, allocatedSize: 400),
        ]
        let store = try Self.assemble(
            completedByKey: completed,
            childrenKeysByKey: [[]],
            hardLinkClaims: claims,
            minimumAllocatedSizeByNodeID: [h2.id: 120]
        )
        #expect(store.node(id: "/root/a2")?.allocatedSize == 120)
        #expect(store.root.allocatedSize == 520)
    }

    // MARK: - Clone-family deduplication

    @Test func cloneFamilyDeduplicationChargesPrivateSize() throws {
        let family = CloneInfo(device: 1, cloneID: 99, refCount: 2, privateSize: 50)
        let c1 = Self.fileRecord("/root/c1", name: "c1", alloc: 300, cloneInfo: family)
        let c2 = Self.fileRecord("/root/c2", name: "c2", alloc: 300, cloneInfo: family)
        let completed: [ScanEngine.CompletedDirScan?] = [
            Self.traversableScan("/root", depth: 0, directLeaves: [c1, c2]),
        ]
        let store = try Self.assemble(completedByKey: completed, childrenKeysByKey: [[]])

        #expect(store.node(id: "/root/c1")?.allocatedSize == 300) // kept member
        #expect(store.node(id: "/root/c2")?.allocatedSize == 50)  // charged private size
        #expect(store.root.allocatedSize == 350)
    }

    // MARK: - Duplicate node id and missing root

    @Test func duplicateNodeIDDroppedWithWarning() throws {
        // Per-directory childPairs dedup keeps the first occurrence, so force
        // the same id under two different parents: the second occurrence to
        // reach the flatten pass is dropped and a warning surfaces.
        let dup = Self.fileRecord("/dup", name: "dup", alloc: 10)
        let completed: [ScanEngine.CompletedDirScan?] = [
            Self.traversableScan("/root", depth: 0),     // 0
            Self.traversableScan("/root/A", depth: 1),   // 1
            Self.traversableScan("/root/B", depth: 1),   // 2
            Self.leafScan(dup, depth: 2),                // 3 (child of A)
            Self.leafScan(dup, depth: 2),                // 4 (child of B, same id)
        ]
        var warnings: [ScanWarning] = []
        // The fast path materializes the duplicate, NodeIDIndex.building
        // detects it, and the assembler falls back to legacyAssemble, which
        // dedups and warns.
        let store = try ScanTreeAssembler.assemble(
            completedByKey: completed,
            childrenKeysByKey: [[1, 2], [3], [4], [], []],
            nextKey: 5,
            hardLinkClaims: [],
            minimumAllocatedSizeByNodeID: [:],
            targetURL: Self.url("/root", isDirectory: true),
            diagnostics: nil,
            callbacks: ScanTreeAssembler.Callbacks(warning: { warnings.append($0) })
        )
        // root + A + B + one surviving dup (the second dropped).
        #expect(store.nodeCount == 4)
        #expect(store.node(id: "/dup") != nil)
        #expect(!warnings.isEmpty)
    }

    @Test func missingRootThrows() {
        // No key 0 → the assembler cannot resolve a root.
        let completed: [ScanEngine.CompletedDirScan?] = [nil]
        #expect(throws: ScanEngine.ScanEngineError.self) {
            _ = try Self.assemble(completedByKey: completed, childrenKeysByKey: [[]])
        }
    }
}
