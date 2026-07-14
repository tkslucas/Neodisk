import Testing
import Foundation
@testable import NeodiskKit

@Suite struct FileTreeStoreReplacingSubtreesTests {
    // MARK: - Multi-subtree re-aggregation

    @Test func testReplacesMultipleSubtreesReaggregatingSharedAndDisjointAncestors() throws {
        // Two targets share the ancestor /root/shared, a third lives in a
        // disjoint branch /root/other.
        let t1Child = makeTestFileNode(id: "/root/shared/t1/a", name: "a", size: 10)
        let t1 = makeTestDirectoryNode(id: "/root/shared/t1", name: "t1", children: [t1Child])
        let t2Child = makeTestFileNode(id: "/root/shared/t2/a", name: "a", size: 20)
        let t2 = makeTestDirectoryNode(id: "/root/shared/t2", name: "t2", children: [t2Child])
        let shared = makeTestDirectoryNode(id: "/root/shared", name: "shared", children: [t1, t2])
        let t3Child = makeTestFileNode(id: "/root/other/t3/a", name: "a", size: 30)
        let t3 = makeTestDirectoryNode(id: "/root/other/t3", name: "t3", children: [t3Child])
        let other = makeTestDirectoryNode(id: "/root/other", name: "other", children: [t3])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [shared, other])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [shared, other],
            shared.id: [t1, t2],
            other.id: [t3],
            t1.id: [t1Child],
            t2.id: [t2Child],
            t3.id: [t3Child],
        ])

        // New subtrees with different totals: t1 100, t2 200, t3 300.
        let newT1 = makeReplacement(id: "/root/shared/t1", name: "t1", childSize: 100)
        let newT2 = makeReplacement(id: "/root/shared/t2", name: "t2", childSize: 200)
        let newT3 = makeReplacement(id: "/root/other/t3", name: "t3", childSize: 300)

        let result = try #require(try store.replacingSubtrees(
            [(id: t1.id, store: newT1), (id: t2.id, store: newT2), (id: t3.id, store: newT3)],
            cancellationCheck: {}
        ))

        #expect(result.node(id: shared.id)?.allocatedSize == 300)   // 100 + 200
        #expect(result.node(id: other.id)?.allocatedSize == 300)
        #expect(result.node(id: root.id)?.allocatedSize == 600)
        #expect(result.node(id: "/root/shared/t1/leaf")?.allocatedSize == 100)
        #expect(result.node(id: "/root/other/t3/leaf")?.allocatedSize == 300)
        // Old leaves are gone.
        #expect(result.node(id: t1Child.id) == nil)
        #expect(result.node(id: t3Child.id) == nil)
    }

    @Test func testReplacementTotalPropagatesToRootAllocatedLogicalAndFileCount() throws {
        let oldLeaf = makeTestFileNode(id: "/root/branch/target/old", name: "old", size: 5)
        let target = makeTestDirectoryNode(id: "/root/branch/target", name: "target", children: [oldLeaf])
        let branch = makeTestDirectoryNode(id: "/root/branch", name: "branch", children: [target])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [branch])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [branch],
            branch.id: [target],
            target.id: [oldLeaf],
        ])
        #expect(store.aggregateStats.totalAllocatedSize == 5)
        #expect(store.aggregateStats.fileCount == 1)

        // Replacement has three files summing to 999.
        let a = makeTestFileNode(id: "/root/branch/target/a", name: "a", size: 300)
        let b = makeTestFileNode(id: "/root/branch/target/b", name: "b", size: 400)
        let c = makeTestFileNode(id: "/root/branch/target/c", name: "c", size: 299)
        let newTarget = makeTestDirectoryNode(id: target.id, name: "target", children: [a, b, c])
        let replacement = FileTreeStore(root: newTarget, childrenByID: [newTarget.id: [a, b, c]])

        let result = try #require(try store.replacingSubtrees(
            [(id: target.id, store: replacement)],
            cancellationCheck: {}
        ))

        #expect(result.node(id: root.id)?.allocatedSize == 999)
        #expect(result.node(id: root.id)?.logicalSize == 999)
        #expect(result.node(id: root.id)?.descendantFileCount == 3)
        #expect(result.aggregateStats.totalAllocatedSize == 999)
        #expect(result.aggregateStats.totalLogicalSize == 999)
        #expect(result.aggregateStats.fileCount == 3)
    }

    // MARK: - Validation

    @Test func testOverlappingTargetsThrow() throws {
        let leaf = makeTestFileNode(id: "/root/a/b/leaf", name: "leaf", size: 1)
        let b = makeTestDirectoryNode(id: "/root/a/b", name: "b", children: [leaf])
        let a = makeTestDirectoryNode(id: "/root/a", name: "a", children: [b])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [a],
            a.id: [b],
            b.id: [leaf],
        ])
        let replA = makeReplacement(id: a.id, name: "a", childSize: 9)
        let replB = makeReplacement(id: b.id, name: "b", childSize: 9)

        let error = try #require(throws: (any Error).self) {
            try store.replacingSubtrees(
                [(id: a.id, store: replA), (id: b.id, store: replB)],
                cancellationCheck: {}
            )
        }
        #expect(error.localizedDescription.contains("overlap"))
        #expect(store.replacingSubtrees([(id: a.id, store: replA), (id: b.id, store: replB)]) == nil)
    }

    @Test func testDuplicateTargetThrowsAsOverlap() throws {
        let store = makeTwoBranchStore()
        let repl = makeReplacement(id: "/root/a/t", name: "t", childSize: 9)

        let error = try #require(throws: (any Error).self) {
            try store.replacingSubtrees(
                [(id: "/root/a/t", store: repl), (id: "/root/a/t", store: repl)],
                cancellationCheck: {}
            )
        }
        #expect(error.localizedDescription.contains("overlap"))
    }

    @Test func testCollisionAcrossTwoReplacementStoresThrows() throws {
        let store = makeTwoBranchStore()
        // Two replacements both introduce a brand-new id "/root/dup".
        let dup1 = makeTestFileNode(id: "/root/dup", name: "dup", size: 3)
        let r1 = makeTestDirectoryNode(id: "/root/a/t", name: "t", children: [dup1])
        let repl1 = FileTreeStore(root: r1, childrenByID: [r1.id: [dup1]])
        let dup2 = makeTestFileNode(id: "/root/dup", name: "dup", size: 7)
        let r2 = makeTestDirectoryNode(id: "/root/b/t", name: "t", children: [dup2])
        let repl2 = FileTreeStore(root: r2, childrenByID: [r2.id: [dup2]])

        let error = try #require(throws: (any Error).self) {
            try store.replacingSubtrees(
                [(id: "/root/a/t", store: repl1), (id: "/root/b/t", store: repl2)],
                cancellationCheck: {}
            )
        }
        #expect(error.localizedDescription.contains("reuses an existing node ID"))
        #expect(error.localizedDescription.contains("/root/dup"))
    }

    @Test func testCollisionWithSurvivingTreeOutsideReplacedSubtreesThrows() throws {
        let store = makeTwoBranchStore()
        // Replacement for /root/a/t reuses /root/b (a surviving node not being replaced).
        let collide = makeTestFileNode(id: "/root/b", name: "b", size: 3)
        let r = makeTestDirectoryNode(id: "/root/a/t", name: "t", children: [collide])
        let repl = FileTreeStore(root: r, childrenByID: [r.id: [collide]])

        let error = try #require(throws: (any Error).self) {
            try store.replacingSubtrees([(id: "/root/a/t", store: repl)], cancellationCheck: {})
        }
        #expect(error.localizedDescription.contains("reuses an existing node ID"))
        #expect(error.localizedDescription.contains("/root/b"))
    }

    @Test func testIDReusedInsideOwnReplacedSubtreeIsFine() throws {
        let oldInner = makeTestFileNode(id: "/root/a/t/inner", name: "inner", size: 1)
        let t = makeTestDirectoryNode(id: "/root/a/t", name: "t", children: [oldInner])
        let a = makeTestDirectoryNode(id: "/root/a", name: "a", children: [t])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [a],
            a.id: [t],
            t.id: [oldInner],
        ])
        // Replacement reuses /root/a/t/inner (inside the subtree being replaced).
        let reusedInner = makeTestFileNode(id: "/root/a/t/inner", name: "inner", size: 42)
        let newT = makeTestDirectoryNode(id: t.id, name: "t", children: [reusedInner])
        let repl = FileTreeStore(root: newT, childrenByID: [newT.id: [reusedInner]])

        let result = try #require(try store.replacingSubtrees(
            [(id: t.id, store: repl)],
            cancellationCheck: {}
        ))
        #expect(result.node(id: "/root/a/t/inner")?.allocatedSize == 42)
        #expect(result.node(id: root.id)?.allocatedSize == 42)
    }

    @Test func testMissingTargetReturnsNil() throws {
        let store = makeTwoBranchStore()
        let repl = makeReplacement(id: "/root/a/t", name: "t", childSize: 9)
        let missing = makeReplacement(id: "/root/nope", name: "nope", childSize: 9)

        let result = try store.replacingSubtrees(
            [(id: "/root/a/t", store: repl), (id: "/root/nope", store: missing)],
            cancellationCheck: {}
        )
        #expect(result == nil)
    }

    @Test func testRootTargetReturnsNil() throws {
        let store = makeTwoBranchStore()
        let repl = makeReplacement(id: "/root", name: "root", childSize: 9)

        let result = try store.replacingSubtrees([(id: "/root", store: repl)], cancellationCheck: {})
        #expect(result == nil)
    }

    @Test func testEmptyReplacementsReturnsSelf() throws {
        let store = makeTwoBranchStore()

        // Documented semantics: an empty replacement list is a no-op that
        // returns an equivalent store.
        let result = try #require(try store.replacingSubtrees([], cancellationCheck: {}))
        #expect(result.rootID == store.rootID)
        #expect(result.nodeCount == store.nodeCount)
        #expect(result.node(id: "/root")?.allocatedSize == store.node(id: "/root")?.allocatedSize)
    }

    // MARK: - Hard-link rebalance across a splice boundary

    @Test func testHardLinkRebalanceMovesSizeToSurvivorAcrossSpliceBoundary() throws {
        // Two hard links to the same inode: /root/a/link (owns the size after
        // dedup, because it sorts first) and /root/b/link (0 after dedup).
        let identity = FileIdentity.fileSystem(device: 1, inode: 1)
        let insideLink = makeTestFileNode(
            id: "/root/a/link", name: "link", size: 100, fileIdentity: identity, linkCount: 2
        )
        let outsideLink = makeTestFileNode(
            id: "/root/b/link", name: "link", size: 100, fileIdentity: identity, linkCount: 2
        )
        let a = makeTestDirectoryNode(id: "/root/a", name: "a", children: [insideLink])
        let b = makeTestDirectoryNode(id: "/root/b", name: "b", children: [outsideLink])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a, b])
        let rawStore = FileTreeStore(root: root, childrenByID: [
            root.id: [a, b],
            a.id: [insideLink],
            b.id: [outsideLink],
        ])
        let baseline = try HardLinkDeduplicator.rebalancedStore(rawStore)
        // Sanity: baseline has the inside link owning the size, outside at 0.
        #expect(baseline.node(id: "/root/a/link")?.allocatedSize == 100)
        #expect(baseline.node(id: "/root/b/link")?.allocatedSize == 0)

        // Replace /root/a with a subtree that drops the hard link entirely.
        let plain = makeTestFileNode(id: "/root/a/plain", name: "plain", size: 5)
        let newA = makeTestDirectoryNode(id: "/root/a", name: "a", children: [plain])
        let replA = FileTreeStore(root: newA, childrenByID: [newA.id: [plain]])

        let result = try #require(try baseline.replacingSubtrees(
            [(id: "/root/a", store: replA)],
            cancellationCheck: {}
        ))

        // The surviving outside link now owns the full size.
        #expect(result.node(id: "/root/a/link") == nil)
        #expect(result.node(id: "/root/b/link")?.allocatedSize == 100)
        #expect(result.node(id: "/root/b")?.allocatedSize == 100)
        #expect(result.node(id: "/root/a")?.allocatedSize == 5)
        #expect(result.node(id: "/root")?.allocatedSize == 105)
    }

    // MARK: - Aggregate stats consistency

    @Test func testAggregateStatsMatchFreshlyBuiltEquivalentTree() throws {
        let t1Child = makeTestFileNode(id: "/root/x/t1/a", name: "a", size: 10)
        let t1 = makeTestDirectoryNode(id: "/root/x/t1", name: "t1", children: [t1Child])
        let t2Child = makeTestFileNode(id: "/root/y/t2/a", name: "a", size: 20)
        let t2 = makeTestDirectoryNode(id: "/root/y/t2", name: "t2", children: [t2Child])
        let x = makeTestDirectoryNode(id: "/root/x", name: "x", children: [t1])
        let y = makeTestDirectoryNode(id: "/root/y", name: "y", children: [t2])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [x, y])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [x, y],
            x.id: [t1],
            y.id: [t2],
            t1.id: [t1Child],
            t2.id: [t2Child],
        ])

        // New t1 (two files), new t2 (one file).
        let n1a = makeTestFileNode(id: "/root/x/t1/n1", name: "n1", size: 111)
        let n1b = makeTestFileNode(id: "/root/x/t1/n2", name: "n2", size: 222)
        let newT1 = makeTestDirectoryNode(id: t1.id, name: "t1", children: [n1a, n1b])
        let repl1 = FileTreeStore(root: newT1, childrenByID: [newT1.id: [n1a, n1b]])
        let n2a = makeTestFileNode(id: "/root/y/t2/m1", name: "m1", size: 333)
        let newT2 = makeTestDirectoryNode(id: t2.id, name: "t2", children: [n2a])
        let repl2 = FileTreeStore(root: newT2, childrenByID: [newT2.id: [n2a]])

        let result = try #require(try store.replacingSubtrees(
            [(id: t1.id, store: repl1), (id: t2.id, store: repl2)],
            cancellationCheck: {}
        ))

        // Build the same final tree directly.
        let freshT1 = makeTestDirectoryNode(id: t1.id, name: "t1", children: [n1a, n1b])
        let freshT2 = makeTestDirectoryNode(id: t2.id, name: "t2", children: [n2a])
        let freshX = makeTestDirectoryNode(id: x.id, name: "x", children: [freshT1])
        let freshY = makeTestDirectoryNode(id: y.id, name: "y", children: [freshT2])
        let freshRoot = makeTestDirectoryNode(id: root.id, name: "root", children: [freshX, freshY])
        let fresh = FileTreeStore(root: freshRoot, childrenByID: [
            freshRoot.id: [freshX, freshY],
            freshX.id: [freshT1],
            freshY.id: [freshT2],
            freshT1.id: [n1a, n1b],
            freshT2.id: [n2a],
        ])

        #expect(result.aggregateStats.totalAllocatedSize == fresh.aggregateStats.totalAllocatedSize)
        #expect(result.aggregateStats.totalLogicalSize == fresh.aggregateStats.totalLogicalSize)
        #expect(result.aggregateStats.fileCount == fresh.aggregateStats.fileCount)
        #expect(result.aggregateStats.directoryCount == fresh.aggregateStats.directoryCount)
        #expect(result.aggregateStats.accessibleItemCount == fresh.aggregateStats.accessibleItemCount)
        #expect(result.aggregateStats.inaccessibleItemCount == fresh.aggregateStats.inaccessibleItemCount)
        #expect(result.node(id: root.id)?.allocatedSize == 666)
    }

    // MARK: - Warnings helper

    @Test func testMergedWarningsPrunesReplacedRootsKeepsOthersMergesAndDedupes() {
        let existing = [
            ScanWarning(path: "/root/a/deep", message: "m1", category: .permissionDenied),
            ScanWarning(path: "/root/b/keep", message: "m2", category: .fileSystem),
            ScanWarning(path: "/root/a", message: "m3", category: .fileSystem),
        ]
        let additional = [
            ScanWarning(path: "/root/a/new", message: "n1", category: .permissionDenied),
            // Exact duplicate of a surviving existing warning.
            ScanWarning(path: "/root/b/keep", message: "m2", category: .fileSystem),
        ]

        let merged = ScanSnapshot.mergedWarningsPruningReplacedSubtrees(
            existing: existing,
            replacedRootPaths: ["/root/a"],
            additional: additional
        )

        // Warnings under /root/a are pruned; surviving existing come first,
        // then additional, deduped by id.
        #expect(merged.map(\.path) == ["/root/b/keep", "/root/a/new"])
        #expect(merged.count == 2)
    }

    // MARK: - Fixtures

    private func makeReplacement(id: String, name: String, childSize: Int64) -> FileTreeStore {
        let leaf = makeTestFileNode(id: id + "/leaf", name: "leaf", size: childSize)
        let dir = makeTestDirectoryNode(id: id, name: name, children: [leaf])
        return FileTreeStore(root: dir, childrenByID: [dir.id: [leaf]])
    }

    private func makeTwoBranchStore() -> FileTreeStore {
        let at = makeTestDirectoryNode(
            id: "/root/a/t", name: "t",
            children: [makeTestFileNode(id: "/root/a/t/x", name: "x", size: 1)]
        )
        let a = makeTestDirectoryNode(id: "/root/a", name: "a", children: [at])
        let bt = makeTestDirectoryNode(
            id: "/root/b/t", name: "t",
            children: [makeTestFileNode(id: "/root/b/t/x", name: "x", size: 2)]
        )
        let b = makeTestDirectoryNode(id: "/root/b", name: "b", children: [bt])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [a, b])
        return FileTreeStore(root: root, childrenByID: [
            root.id: [a, b],
            a.id: [at],
            b.id: [bt],
            at.id: [makeTestFileNode(id: "/root/a/t/x", name: "x", size: 1)],
            bt.id: [makeTestFileNode(id: "/root/b/t/x", name: "x", size: 2)],
        ])
    }
}
