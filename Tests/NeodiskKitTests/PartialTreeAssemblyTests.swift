import Foundation
import Testing
@testable import NeodiskKit

/// Drives `ScanEngine.assemblePartialTree` directly with synthetic phase-1
/// state:
///
///     /root            key 0, depth 0
///     ├── f0           key 1, depth 1, 100 bytes
///     └── a/           key 2, depth 1
///         └── b/       key 3, depth 2
///             └── deep key 4, depth 3, 7 bytes
@Suite struct PartialTreeAssemblyTests {
    private static func directoryMetadata(isReadable: Bool = true) -> NodeMetadata {
        NodeMetadata(
            isDirectory: true,
            isPackage: false,
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

    private static func leafScan(_ node: FileNodeRecord, depth: Int) -> ScanEngine.CompletedDirScan {
        ScanEngine.CompletedDirScan(
            node: node,
            metadata: NodeMetadata(
                isDirectory: false,
                isPackage: false,
                isSymbolicLink: false,
                logicalSize: node.logicalSize,
                allocatedSize: node.allocatedSize,
                lastModified: nil,
                isReadable: true,
                volumeUsedCapacity: nil,
                fileIdentity: nil,
                linkCount: 1
            ),
            url: node.url,
            isTraversable: false,
            depth: depth
        )
    }

    private static func directoryScan(_ path: String, depth: Int) -> ScanEngine.CompletedDirScan {
        ScanEngine.CompletedDirScan(
            node: nil,
            metadata: directoryMetadata(),
            url: URL(filePath: path, directoryHint: .isDirectory),
            isTraversable: true,
            depth: depth
        )
    }

    private var completedByKey: [ScanEngine.CompletedDirScan?] {
        [
            Self.directoryScan("/root", depth: 0),
            Self.leafScan(makeTestFileNode(id: "/root/f0", name: "f0", size: 100), depth: 1),
            Self.directoryScan("/root/a", depth: 1),
            Self.directoryScan("/root/a/b", depth: 2),
            Self.leafScan(makeTestFileNode(id: "/root/a/b/deep", name: "deep", size: 7), depth: 3),
        ]
    }

    private let childrenKeysByKey: [[Int]] = [[1, 2], [], [3], [4], []]

    @Test func depthLimitAggregatesDeepSubtreesIntoAncestor() throws {
        let store = try #require(ScanEngine.assemblePartialTree(
            completedByKey: completedByKey,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: 5,
            maxDepth: 1
        ))

        // Only root, f0, and the depth-limit directory `a` are materialized.
        #expect(store.nodeCount == 3)
        #expect(store.node(id: "/root/a/b") == nil)
        #expect(store.node(id: "/root/a/b/deep") == nil)

        // `a` appears as a childless directory carrying its subtree totals.
        let aggregated = try #require(store.node(id: "/root/a"))
        #expect(aggregated.isDirectory)
        #expect(!store.containsChildren(id: aggregated.id))
        #expect(aggregated.allocatedSize == 7)
        #expect(aggregated.descendantFileCount == 1)

        // The root total still counts everything scanned so far.
        #expect(store.root.allocatedSize == 107)
        #expect(store.root.descendantFileCount == 2)
    }

    @Test func unlimitedDepthMaterializesTheWholeTree() throws {
        let store = try #require(ScanEngine.assemblePartialTree(
            completedByKey: completedByKey,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: 5,
            maxDepth: Int.max
        ))

        #expect(store.nodeCount == 5)
        #expect(store.node(id: "/root/a/b/deep")?.allocatedSize == 7)
        #expect(store.root.allocatedSize == 107)
    }

    @Test func missingDeepChildrenAreTolerated() throws {
        // Key 4 (the deep file) has not been scanned yet.
        var incomplete = completedByKey
        incomplete[4] = nil

        let store = try #require(ScanEngine.assemblePartialTree(
            completedByKey: incomplete,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: 5,
            maxDepth: 1
        ))

        #expect(store.node(id: "/root/a")?.allocatedSize == 0)
        #expect(store.root.allocatedSize == 100)
    }

    @Test func batchedDirectLeavesMaterializeAndRollUpAtDepthLimit() throws {
        let rootLeaf = makeTestFileNode(id: "/root/direct", name: "direct", size: 100)
        let deepLeaf = makeTestFileNode(id: "/root/a/b/deep", name: "deep", size: 7)
        let root = ScanEngine.CompletedDirScan(
            node: nil,
            directLeafNodes: [rootLeaf],
            metadata: Self.directoryMetadata(),
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            isTraversable: true,
            depth: 0
        )
        let a = Self.directoryScan("/root/a", depth: 1)
        let b = ScanEngine.CompletedDirScan(
            node: nil,
            directLeafNodes: [deepLeaf],
            metadata: Self.directoryMetadata(),
            url: URL(filePath: "/root/a/b", directoryHint: .isDirectory),
            isTraversable: true,
            depth: 2
        )

        let store = try #require(ScanEngine.assemblePartialTree(
            completedByKey: [root, a, b],
            childrenKeysByKey: [[1], [2], []],
            nextKey: 3,
            maxDepth: 1
        ))

        #expect(store.nodeCount == 3)
        #expect(store.node(id: rootLeaf.id)?.allocatedSize == 100)
        #expect(store.node(id: deepLeaf.id) == nil)
        #expect(store.node(id: "/root/a")?.allocatedSize == 7)
        #expect(store.root.allocatedSize == 107)
        #expect(store.root.descendantFileCount == 2)
    }
}
