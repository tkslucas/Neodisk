import Foundation
import Testing
@testable import NeodiskKit

/// Proves the numeric `HardLinkDeduplicator.rebuildAffectedAncestors` is
/// byte-identical to the retained `legacyRebuildAffectedAncestors` oracle, and
/// that both post-assembly dedup entry points (`HardLinkDeduplicator` /
/// `CloneDeduplicator.applyDeduplication`) produce field-identical stores with
/// either rebuild. The splice path (`SharedSizeDeduplication.rebalancedStore`)
/// funnels through the same rebuild, so the direct equivalence covers it; a
/// self-consistency + idempotence check exercises it end-to-end.
@Suite struct DedupRebuildEquivalenceTests {
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

    private final class StoreBuilder {
        var rng: SeededGenerator
        var counter = 0
        var cloneSeed: UInt64 = 1
        var childrenByID: [String: [FileNodeRecord]] = [:]
        init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        func size() -> Int64 {
            let choices: [Int64] = [0, 4096, 4096, 4096, 8192, 8192, 12288, 65536, 1_000_003]
            return choices[int(0...(choices.count - 1))]
        }

        func file(_ path: String, name: String) -> FileNodeRecord {
            let isSymlink = chance(0.05)
            let alloc = isSymlink ? 0 : size()
            var cloneInfo: CloneInfo?
            if !isSymlink, chance(0.12) {
                // Clone-family member (shared id across a few files), private
                // size stamped so no syscall is needed.
                cloneInfo = CloneInfo(
                    device: 1,
                    cloneID: UInt64(int(1...6)),          // small pool → shared families
                    refCount: 2,
                    privateSize: Int64(int(0...4096))
                )
            }
            return FileNodeRecord(
                id: path, url: URL(filePath: path), name: name,
                isDirectory: false, isSymbolicLink: isSymlink,
                allocatedSize: alloc, logicalSize: alloc,
                descendantFileCount: isSymlink ? 0 : 1,
                lastModified: nil, fileIdentity: nil, linkCount: 1,
                isPackage: false, isAccessible: true, isSelfAccessible: true,
                isSynthetic: false, isAutoSummarized: false, cloneInfo: cloneInfo
            )
        }

        func dirLeaf(_ path: String, name: String) -> FileNodeRecord {
            FileNodeRecord(
                id: path, url: URL(filePath: path, directoryHint: .isDirectory), name: name,
                isDirectory: true, isSymbolicLink: false,
                allocatedSize: size(), logicalSize: size(), descendantFileCount: int(0...50),
                lastModified: nil, fileIdentity: nil, linkCount: 1,
                isPackage: chance(0.3), isAccessible: chance(0.85),
                isSelfAccessible: true, isSynthetic: false, isAutoSummarized: chance(0.2)
            )
        }

        func buildDir(_ path: String, name: String, depth: Int, maxDepth: Int) -> FileNodeRecord {
            var children: [FileNodeRecord] = []
            for _ in 0..<int(1...5) {
                counter += 1
                children.append(file("\(path)/f\(counter)", name: "f\(counter)"))
            }
            if depth < maxDepth {
                for _ in 0..<(depth < 3 ? int(2...4) : int(0...3)) {
                    counter += 1
                    if chance(0.25) {
                        children.append(dirLeaf("\(path)/d\(counter)", name: "d\(counter)"))
                    } else {
                        children.append(buildDir("\(path)/d\(counter)", name: "d\(counter)", depth: depth + 1, maxDepth: maxDepth))
                    }
                }
            }
            let dir = FileNodeRecord.directory(
                id: path, url: URL(filePath: path, directoryHint: .isDirectory), name: name,
                children: children, lastModified: nil,
                isPackage: chance(0.1), isAccessible: chance(0.9)
            )
            childrenByID[path] = children
            return dir
        }

        func build(maxDepth: Int) -> FileTreeStore {
            let root = buildDir("/root", name: "root", depth: 0, maxDepth: maxDepth)
            return FileTreeStore(root: root, childrenByID: childrenByID)
        }
    }

    private static func recordsEqual(_ x: FileNodeRecord, _ y: FileNodeRecord) -> Bool {
        x.id == y.id && x.path == y.path && x.name == y.name
            && x.isDirectory == y.isDirectory && x.isSymbolicLink == y.isSymbolicLink
            && x.allocatedSize == y.allocatedSize
            && x.unduplicatedAllocatedSize == y.unduplicatedAllocatedSize
            && x.logicalSize == y.logicalSize
            && x.descendantFileCount == y.descendantFileCount
            && x.lastModified == y.lastModified && x.fileIdentity == y.fileIdentity
            && x.linkCount == y.linkCount && x.isPackage == y.isPackage
            && x.isAccessible == y.isAccessible && x.isSelfAccessible == y.isSelfAccessible
            && x.isSynthetic == y.isSynthetic && x.isAutoSummarized == y.isAutoSummarized
            && x.isDataless == y.isDataless
            && x.cloudOnlyLogicalSize == y.cloudOnlyLogicalSize
            && x.cloneInfo == y.cloneInfo
    }

    private static func assertNodesEqual(_ a: [FileNodeRecord], _ b: [FileNodeRecord], _ label: String) {
        #expect(a.count == b.count, "\(label): node count")
        guard a.count == b.count else { return }
        for i in 0..<a.count where !recordsEqual(a[i], b[i]) {
            Issue.record("\(label): node \(i) differs (\(a[i].id): \(a[i].allocatedSize) vs \(b[i].allocatedSize))")
            return
        }
    }

    private let legacyRebuild: HardLinkDeduplicator.AncestorRebuild = { changed, nodes, parentIndices, childStarts, childSlots in
        HardLinkDeduplicator.legacyRebuildAffectedAncestors(
            of: changed, nodes: &nodes,
            parentIndices: parentIndices, childStarts: childStarts, childSlots: &childSlots,
            cancellationCheck: {}
        )
    }

    // MARK: - Direct rebuild equivalence (the core proof)

    @Test(arguments: [1, 7, 13, 42, 99, 2024, 31337] as [UInt64])
    func numericRebuildMatchesLegacy(seed: UInt64) {
        var gen = SeededGenerator(seed: seed)
        let store = StoreBuilder(seed: seed).build(maxDepth: 6)
        let storage = store.storage
        #expect(storage.nodes.count > 5)

        // Apply random size reductions to a random subset of leaf files.
        let leafIndices = storage.nodes.indices.filter {
            !storage.nodes[$0].isDirectory
        }
        var legacyNodes = storage.nodes
        var numericNodes = storage.nodes
        var changed = Set<Int32>()
        for i in leafIndices where Bool.random(using: &gen) {
            let old = storage.nodes[i].allocatedSize
            let reduced = max(0, old - Int64.random(in: 0...max(old, 1), using: &gen))
            legacyNodes[i] = legacyNodes[i].replacingAllocatedSize(reduced)
            numericNodes[i] = numericNodes[i].replacingAllocatedSize(reduced)
            changed.insert(Int32(i))
        }

        var legacySlots = storage.childSlots
        var numericSlots = storage.childSlots
        HardLinkDeduplicator.legacyRebuildAffectedAncestors(
            of: changed, nodes: &legacyNodes,
            parentIndices: storage.parentIndices, childStarts: storage.childStarts, childSlots: &legacySlots,
            cancellationCheck: {}
        )
        HardLinkDeduplicator.rebuildAffectedAncestors(
            of: changed, nodes: &numericNodes,
            parentIndices: storage.parentIndices, childStarts: storage.childStarts, childSlots: &numericSlots,
            cancellationCheck: {}
        )

        #expect(legacySlots == numericSlots, "seed \(seed): childSlots")
        Self.assertNodesEqual(legacyNodes, numericNodes, "seed \(seed)")
    }

    // MARK: - Post-assembly call site: hard-link applyDeduplication

    @Test(arguments: [2, 8, 20, 77, 500] as [UInt64])
    func hardLinkApplyDeduplicationMatchesLegacyRebuild(seed: UInt64) {
        var gen = SeededGenerator(seed: seed)
        let store = StoreBuilder(seed: seed &+ 1).build(maxDepth: 6)
        let storage = store.storage

        // Build hard-link claims from random groups of real files.
        let fileNodes = storage.nodes.filter { !$0.isDirectory && !$0.isSymbolicLink && $0.allocatedSize > 0 }
        var claims: [HardLinkClaim] = []
        var minimums: [String: Int64] = [:]
        var inode: UInt64 = 1
        var i = 0
        while i < fileNodes.count {
            let familySize = min(fileNodes.count - i, Int.random(in: 1...3, using: &gen))
            if familySize >= 2, Bool.random(using: &gen) {
                let identity = FileIdentity(device: 1, inode: inode); inode += 1
                for j in i..<(i + familySize) {
                    let f = fileNodes[j]
                    claims.append(HardLinkClaim(identity: identity, ownerNodeID: f.id, path: f.path, allocatedSize: f.allocatedSize))
                    if Bool.random(using: &gen) { minimums[f.id] = f.allocatedSize / 4 }
                }
            }
            i += familySize
        }

        var numericNodes = storage.nodes, numericSlots = storage.childSlots
        HardLinkDeduplicator.applyDeduplication(
            nodes: &numericNodes, parentIndices: storage.parentIndices, childStarts: storage.childStarts,
            childSlots: &numericSlots, indexByID: storage.indexByID,
            hardLinkClaims: claims, minimumAllocatedSizeByNodeID: minimums
        )
        var legacyNodes = storage.nodes, legacySlots = storage.childSlots
        HardLinkDeduplicator.applyDeduplication(
            nodes: &legacyNodes, parentIndices: storage.parentIndices, childStarts: storage.childStarts,
            childSlots: &legacySlots, indexByID: storage.indexByID,
            hardLinkClaims: claims, minimumAllocatedSizeByNodeID: minimums,
            rebuild: legacyRebuild
        )

        #expect(numericSlots == legacySlots, "seed \(seed): childSlots")
        Self.assertNodesEqual(numericNodes, legacyNodes, "seed \(seed)")
    }

    // MARK: - Post-assembly call site: clone applyDeduplication

    @Test(arguments: [3, 11, 29, 88, 611] as [UInt64])
    func cloneApplyDeduplicationMatchesLegacyRebuild(seed: UInt64) {
        let store = StoreBuilder(seed: seed &+ 2).build(maxDepth: 6)
        let storage = store.storage
        let provider: CloneDeduplicator.PrivateSizeProvider = { _ in 128 }

        var numericNodes = storage.nodes, numericSlots = storage.childSlots
        CloneDeduplicator.applyDeduplication(
            nodes: &numericNodes, parentIndices: storage.parentIndices, childStarts: storage.childStarts,
            childSlots: &numericSlots, indexByID: storage.indexByID, privateSizeProvider: provider,
            cancellationCheck: {}
        )
        var legacyNodes = storage.nodes, legacySlots = storage.childSlots
        CloneDeduplicator.applyDeduplication(
            nodes: &legacyNodes, parentIndices: storage.parentIndices, childStarts: storage.childStarts,
            childSlots: &legacySlots, indexByID: storage.indexByID, privateSizeProvider: provider,
            rebuild: legacyRebuild, cancellationCheck: {}
        )

        #expect(numericSlots == legacySlots, "seed \(seed): childSlots")
        Self.assertNodesEqual(numericNodes, legacyNodes, "seed \(seed)")
    }

    // MARK: - Splice path: rebalancedStore is self-consistent and idempotent

    @Test(arguments: [5, 17, 41, 123] as [UInt64])
    func rebalancedStoreSplicePathIsSelfConsistent(seed: UInt64) throws {
        let store = StoreBuilder(seed: seed &+ 3).build(maxDepth: 6)
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(store)

        // Every directory equals the numeric aggregate of its (display-sorted)
        // children — the invariant the rebuild must preserve.
        assertSelfConsistent(rebalanced, seed: seed)

        // Idempotent: re-running changes nothing (stable fixed point).
        let again = try SharedSizeDeduplication.rebalancedStore(rebalanced)
        #expect(again.storage.childSlots == rebalanced.storage.childSlots, "seed \(seed): idempotent childSlots")
        Self.assertNodesEqual(again.storage.nodes, rebalanced.storage.nodes, "seed \(seed): idempotent nodes")
    }

    private func assertSelfConsistent(_ store: FileTreeStore, seed: UInt64) {
        let storage = store.storage
        for index in storage.nodes.indices where storage.nodes[index].isDirectory {
            let node = storage.nodes[index]
            let childIndices = storage.childIndices(of: Int32(index))
            var allocated: Int64 = 0, logical: Int64 = 0, cloud: Int64 = 0, files = 0
            var accessible = true
            var previous: FileNodeRecord?
            for ci in childIndices {
                let child = storage.nodes[Int(ci)]
                allocated = allocated.addingClamped(child.allocatedSize)
                logical = logical.addingClamped(child.logicalSize)
                cloud = cloud.addingClamped(child.cloudOnlyLogicalSize)
                if child.isDirectory { files += child.descendantFileCount }
                else if !child.isSymbolicLink && !child.isSynthetic { files += 1 }
                accessible = accessible && child.isAccessible
                if let previous, !FileTreeStore.childDisplayOrder(previous, child), FileTreeStore.childDisplayOrder(child, previous) {
                    Issue.record("seed \(seed): children of \(node.id) not in display order")
                    return
                }
                previous = child
            }
            if !childIndices.isEmpty {
                #expect(node.allocatedSize == allocated, "seed \(seed): \(node.id) allocated")
                #expect(node.logicalSize == logical, "seed \(seed): \(node.id) logical")
                #expect(node.cloudOnlyLogicalSize == cloud, "seed \(seed): \(node.id) cloudOnly")
                #expect(node.descendantFileCount == files, "seed \(seed): \(node.id) descendantFileCount")
                #expect(node.isAccessible == (node.isSelfAccessible && accessible), "seed \(seed): \(node.id) accessible")
            }
        }
    }
}
