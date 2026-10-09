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

/// The running-totals partial build must match the full walk it replaced, on
/// random trees with folders still in flight, unreadable folders, and every
/// depth limit.
@Suite struct PartialTreeRunningTotalsEquivalenceTests {
    private static func metadata(isDirectory: Bool, isReadable: Bool) -> NodeMetadata {
        NodeMetadata(
            isDirectory: isDirectory, isPackage: false, isSymbolicLink: false,
            logicalSize: 0, allocatedSize: 0, lastModified: nil, isReadable: isReadable,
            volumeUsedCapacity: nil, fileIdentity: nil, linkCount: 1
        )
    }

    private static func dump(_ store: FileTreeStore) -> [String] {
        var lines: [String] = []
        var stack = [store.rootID]
        while let id = stack.popLast() {
            guard let node = store.node(id: id) else { continue }
            let children = store.children(of: id).map(\.id)
            lines.append("\(id)|\(node.allocatedSize)|\(node.logicalSize)|\(node.descendantFileCount)|\(node.isAccessible)|\(children)")
            stack.append(contentsOf: children)
        }
        return lines
    }

    @Test(arguments: 0..<24)
    func runningTotalsMatchTheFullWalk(seed: Int) throws {
        var generator = SeededGenerator(seed: UInt64(seed + 1))
        for maxDepth in 1...4 {
            var completed: [ScanEngine.CompletedDirScan?] = []
            var childrenKeys: [[Int]] = []
            var totals = ScanEngine.PartialTreeTotals(maxDepth: maxDepth)
            var paths: [String] = []
            var depths: [Int] = []
            // Keys in allocation order: each new key's parent is an earlier folder.
            for key in 0..<60 {
                // Children are only discovered once their folder's listing is
                // in: a parent is a completed folder (the root always is).
                let parent = key == 0 ? -1 : Int.random(in: 0..<key, using: &generator)
                let parentIsListedFolder = parent < 0 || completed[parent]?.isTraversable == true
                let parentKey = parentIsListedFolder ? parent : 0
                let depth = parentKey < 0 ? 0 : depths[parentKey] + 1
                let path = parentKey < 0 ? "/r" : "\(paths[parentKey])/k\(key)"
                paths.append(path)
                depths.append(depth)
                childrenKeys.append([])
                if parentKey >= 0 { childrenKeys[parentKey].append(key) }
                totals.allocate(parentKey: parentKey, depth: depth)
                let roll = Int.random(in: 0..<10, using: &generator)
                if roll < 1 && key > 0 {
                    completed.append(nil) // still in flight
                } else if roll < 6 || key == 0 {
                    let readable = Int.random(in: 0..<8, using: &generator) > 0
                    let leaves = (0..<Int.random(in: 0..<4, using: &generator)).map {
                        makeTestFileNode(id: "\(path)/f\($0)", name: "f\($0)", size: Int64.random(in: 1...999, using: &generator))
                    }
                    completed.append(ScanEngine.CompletedDirScan(
                        node: nil, directLeafNodes: leaves,
                        metadata: Self.metadata(isDirectory: true, isReadable: readable),
                        url: URL(filePath: path, directoryHint: .isDirectory),
                        isTraversable: true, depth: depth
                    ))
                    var leafTotals = ScanEngine.PartialSubtreeTotals()
                    for leaf in leaves { leafTotals.add(ScanEngine.PartialSubtreeTotals(of: leaf)) }
                    leafTotals.isAccessible = leafTotals.isAccessible && readable
                    totals.add(leafTotals, at: key)
                } else {
                    let node = makeTestFileNode(id: path, name: "k\(key)", size: Int64.random(in: 1...999, using: &generator))
                    completed.append(ScanEngine.CompletedDirScan(
                        node: node, metadata: Self.metadata(isDirectory: false, isReadable: true),
                        url: node.url, isTraversable: false, depth: depth
                    ))
                    totals.add(ScanEngine.PartialSubtreeTotals(of: node), at: key)
                }
            }
            let full = try #require(ScanEngine.assemblePartialTree(
                completedByKey: completed, childrenKeysByKey: childrenKeys, nextKey: 60, maxDepth: maxDepth
            ))
            let running = try #require(ScanEngine.assemblePartialTree(
                completedByKey: completed, childrenKeysByKey: childrenKeys, nextKey: 60, runningTotals: totals
            ))
            #expect(Self.dump(full) == Self.dump(running), "seed \(seed) maxDepth \(maxDepth)")
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
