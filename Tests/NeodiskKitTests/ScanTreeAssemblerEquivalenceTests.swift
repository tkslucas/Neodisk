import Foundation
import Testing
@testable import NeodiskKit

/// Proves the numeric fast path (`ScanTreeAssembler.assemble`) produces a
/// `FileTreeStore` field-for-field identical to the verbatim
/// `legacyAssemble` oracle across large randomized phase-1 states, and that a
/// forced duplicate id engages the legacy fallback.
@Suite struct ScanTreeAssemblerEquivalenceTests {
    /// Deterministic SplitMix64 so failures reproduce from the seed.
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

    /// A randomly generated phase-1 state plus the deduplication inputs.
    private struct GeneratedScan {
        var completedByKey: [ScanEngine.CompletedDirScan?] = []
        var childrenKeysByKey: [[Int]] = []
        var hardLinkClaims: [HardLinkClaim] = []
        var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
    }

    private final class ScanBuilder {
        var scan = GeneratedScan()
        var rng: SeededGenerator
        var uniqueCounter = 0
        var hardLinkIdentitySeed: UInt64 = 1
        var cloneIDSeed: UInt64 = 1

        init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

        func int(_ range: ClosedRange<Int>) -> Int {
            Int.random(in: range, using: &rng)
        }

        func chance(_ probability: Double) -> Bool {
            Double.random(in: 0..<1, using: &rng) < probability
        }

        /// Sizes drawn from a small set so ties are frequent (mirrors 4KB
        /// quantization on real volumes).
        func tieProneSize() -> Int64 {
            let choices: [Int64] = [0, 4096, 4096, 4096, 8192, 8192, 12288, 100_000]
            return choices[int(0...(choices.count - 1))]
        }

        func allocateKey() -> Int {
            let key = scan.completedByKey.count
            scan.completedByKey.append(nil)
            scan.childrenKeysByKey.append([])
            return key
        }

        func fileLeaf(_ path: String, name: String) -> FileNodeRecord {
            let size = tieProneSize()
            let isSymlink = chance(0.05)
            var identity: FileIdentity?
            var linkCount: UInt64 = 1
            var cloneInfo: CloneInfo?

            if !isSymlink, chance(0.06) {
                // Hard-link member: pair it with a sibling created alongside.
                identity = FileIdentity(device: 1, inode: hardLinkIdentitySeed)
                hardLinkIdentitySeed += 1
                linkCount = 2
            }
            if !isSymlink, identity == nil, chance(0.06) {
                cloneInfo = CloneInfo(device: 1, cloneID: cloneIDSeed, refCount: 2, privateSize: Int64(int(0...2048)))
                cloneIDSeed += 1
            }

            let record = FileNodeRecord(
                id: path,
                url: URL(filePath: path),
                name: name,
                isDirectory: false,
                isSymbolicLink: isSymlink,
                allocatedSize: isSymlink ? 0 : size,
                logicalSize: isSymlink ? 0 : size,
                descendantFileCount: isSymlink ? 0 : 1,
                lastModified: nil,
                fileIdentity: identity,
                linkCount: linkCount,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false,
                cloneInfo: cloneInfo
            )
            if let identity {
                scan.hardLinkClaims.append(HardLinkClaim(
                    identity: identity, ownerNodeID: record.id, path: record.path, allocatedSize: record.allocatedSize
                ))
            }
            return record
        }

        func keyedLeafRecord(_ path: String, name: String) -> FileNodeRecord {
            let roll = int(0...3)
            let size = tieProneSize()
            switch roll {
            case 0: // package
                return dirLeaf(path, name: name, alloc: size, descendantFileCount: int(1...50), isPackage: true)
            case 1: // auto-summarized
                return dirLeaf(path, name: name, alloc: size, descendantFileCount: int(1...5000), isAutoSummarized: true)
            case 2: // inaccessible directory
                return dirLeaf(path, name: name, alloc: 0, descendantFileCount: 0, isAccessible: false)
            default: // mount-boundary / plain dir leaf
                return dirLeaf(path, name: name, alloc: size, descendantFileCount: 0)
            }
        }

        func dirLeaf(
            _ path: String, name: String, alloc: Int64, descendantFileCount: Int,
            isPackage: Bool = false, isAutoSummarized: Bool = false, isAccessible: Bool = true
        ) -> FileNodeRecord {
            FileNodeRecord(
                id: path,
                url: URL(filePath: path, directoryHint: .isDirectory),
                name: name,
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: alloc,
                logicalSize: alloc,
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

        /// Builds a directory subtree in preorder (parent key < child keys).
        @discardableResult
        func buildDir(_ path: String, depth: Int, maxDepth: Int) -> Int {
            let key = allocateKey()

            var directLeaves: [FileNodeRecord] = []
            let fileCount = depth >= maxDepth ? int(2...10) : int(1...6)
            for _ in 0..<fileCount {
                uniqueCounter += 1
                let name = "f\(uniqueCounter).bin"
                directLeaves.append(fileLeaf("\(path)/\(name)", name: name))
            }

            var childKeys: [Int] = []
            if depth < maxDepth {
                // Branch reliably near the top so the tree is sizable.
                let subdirCount = depth < 4 ? int(3...5) : int(0...3)
                for _ in 0..<subdirCount {
                    uniqueCounter += 1
                    let name = "d\(uniqueCounter)"
                    if chance(0.3) {
                        // Keyed leaf directory (package / summary / inaccessible / mount).
                        let ck = allocateKey()
                        let record = keyedLeafRecord("\(path)/\(name)", name: name)
                        scan.completedByKey[ck] = ScanEngine.CompletedDirScan(
                            node: record,
                            metadata: leafMeta(record),
                            url: record.url,
                            isTraversable: false,
                            depth: depth + 1
                        )
                        childKeys.append(ck)
                    } else {
                        childKeys.append(buildDir("\(path)/\(name)", depth: depth + 1, maxDepth: maxDepth))
                    }
                }
            }

            scan.completedByKey[key] = ScanEngine.CompletedDirScan(
                node: nil,
                directLeafNodes: directLeaves,
                metadata: dirMeta(isReadable: true),
                url: URL(filePath: path, directoryHint: .isDirectory),
                isTraversable: true,
                depth: depth
            )
            scan.childrenKeysByKey[key] = childKeys
            return key
        }

        private func dirMeta(isReadable: Bool) -> NodeMetadata {
            NodeMetadata(
                isDirectory: true, isPackage: false, isSymbolicLink: false,
                logicalSize: 0, allocatedSize: 0, lastModified: nil,
                isReadable: isReadable, volumeUsedCapacity: nil, fileIdentity: nil, linkCount: 1
            )
        }

        private func leafMeta(_ record: FileNodeRecord) -> NodeMetadata {
            NodeMetadata(
                isDirectory: record.isDirectory, isPackage: record.isPackage, isSymbolicLink: false,
                logicalSize: record.logicalSize, allocatedSize: record.allocatedSize, lastModified: nil,
                isReadable: record.isSelfAccessible, volumeUsedCapacity: nil, fileIdentity: nil, linkCount: 1
            )
        }
    }

    private static func recordsEqual(_ x: FileNodeRecord, _ y: FileNodeRecord) -> Bool {
        x.id == y.id && x.path == y.path && x.name == y.name
            && x.isDirectory == y.isDirectory && x.isSymbolicLink == y.isSymbolicLink
            && x.allocatedSize == y.allocatedSize
            && x.unduplicatedAllocatedSize == y.unduplicatedAllocatedSize
            && x.logicalSize == y.logicalSize
            && x.descendantFileCount == y.descendantFileCount
            && x.lastModified == y.lastModified
            && x.fileIdentity == y.fileIdentity
            && x.linkCount == y.linkCount
            && x.isPackage == y.isPackage
            && x.isAccessible == y.isAccessible
            && x.isSelfAccessible == y.isSelfAccessible
            && x.isSynthetic == y.isSynthetic
            && x.isAutoSummarized == y.isAutoSummarized
            && x.isDataless == y.isDataless
            && x.cloudOnlyLogicalSize == y.cloudOnlyLogicalSize
            && x.cloneInfo == y.cloneInfo
    }

    private static func assertStoresEqual(_ fast: FileTreeStore, _ legacy: FileTreeStore) {
        #expect(fast.rootID == legacy.rootID)
        #expect(fast.nodeCount == legacy.nodeCount)

        let fastNodes = fast.allNodes
        let legacyNodes = legacy.allNodes
        #expect(fastNodes.count == legacyNodes.count)
        if fastNodes.count == legacyNodes.count {
            for i in 0..<fastNodes.count where !recordsEqual(fastNodes[i], legacyNodes[i]) {
                Issue.record("node \(i) differs: \(fastNodes[i].id) vs \(legacyNodes[i].id)")
                break
            }
        }

        // Topology and per-node hash arrays.
        #expect(fast.storage.parentIndices == legacy.storage.parentIndices)
        #expect(fast.storage.childStarts == legacy.storage.childStarts)
        #expect(fast.storage.childSlots == legacy.storage.childSlots)
        #expect(fast.storage.nodeHashes == legacy.storage.nodeHashes)

        // Index lookups resolve to the same indices.
        for node in legacyNodes where fast.storage.index(of: node.id) != legacy.storage.index(of: node.id) {
            Issue.record("index lookup differs for \(node.id)")
            break
        }

        // Aggregate stats.
        let a = fast.aggregateStats
        let b = legacy.aggregateStats
        #expect(a.totalAllocatedSize == b.totalAllocatedSize)
        #expect(a.totalLogicalSize == b.totalLogicalSize)
        #expect(a.fileCount == b.fileCount)
        #expect(a.directoryCount == b.directoryCount)
        #expect(a.accessibleItemCount == b.accessibleItemCount)
        #expect(a.inaccessibleItemCount == b.inaccessibleItemCount)
    }

    private static func runBoth(_ scan: GeneratedScan) throws -> (fast: FileTreeStore, legacy: FileTreeStore) {
        let targetURL = URL(filePath: "/root", directoryHint: .isDirectory)
        let fast = try ScanTreeAssembler.assemble(
            completedByKey: scan.completedByKey,
            childrenKeysByKey: scan.childrenKeysByKey,
            nextKey: scan.completedByKey.count,
            hardLinkClaims: scan.hardLinkClaims,
            minimumAllocatedSizeByNodeID: scan.minimumAllocatedSizeByNodeID,
            targetURL: targetURL,
            diagnostics: nil,
            callbacks: ScanTreeAssembler.Callbacks()
        )
        let legacy = try ScanTreeAssembler.legacyAssemble(
            completedByKey: scan.completedByKey,
            childrenKeysByKey: scan.childrenKeysByKey,
            nextKey: scan.completedByKey.count,
            hardLinkClaims: scan.hardLinkClaims,
            minimumAllocatedSizeByNodeID: scan.minimumAllocatedSizeByNodeID,
            targetURL: targetURL,
            diagnostics: nil,
            callbacks: ScanTreeAssembler.Callbacks()
        )
        return (fast, legacy)
    }

    @Test(arguments: [1, 2, 3, 7, 42, 1001] as [UInt64])
    func fastPathMatchesLegacyOnRandomTrees(seed: UInt64) throws {
        let builder = ScanBuilder(seed: seed)
        builder.buildDir("/root", depth: 0, maxDepth: 6)
        // Guard the fixture actually built a sizable tree.
        #expect(builder.scan.completedByKey.count > 50)

        let (fast, legacy) = try Self.runBoth(builder.scan)
        Self.assertStoresEqual(fast, legacy)
    }

    @Test func largeRandomTreeMatchesLegacy() throws {
        let builder = ScanBuilder(seed: 20260716)
        // Wider/deeper for a ~10k+ node tree with ties, hardlinks, clones.
        builder.buildDir("/root", depth: 0, maxDepth: 7)
        #expect(builder.scan.completedByKey.count > 200)

        let (fast, legacy) = try Self.runBoth(builder.scan)
        #expect(fast.nodeCount > 1000)
        Self.assertStoresEqual(fast, legacy)
    }

    @Test func cancellationPropagatesFromChecks() {
        let builder = ScanBuilder(seed: 555)
        builder.buildDir("/root", depth: 0, maxDepth: 7)
        #expect(builder.scan.completedByKey.count > 50)

        // Throw on the 2nd check: whatever the tree size, the assembler makes
        // at least two cancellation checks (step 1 entry, then the post-sort
        // check), so a cancellation surfaces as a CancellationError.
        var calls = 0
        let callbacks = ScanTreeAssembler.Callbacks(cancellationCheck: {
            calls += 1
            if calls > 1 { throw CancellationError() }
        })
        #expect(throws: CancellationError.self) {
            _ = try ScanTreeAssembler.assemble(
                completedByKey: builder.scan.completedByKey,
                childrenKeysByKey: builder.scan.childrenKeysByKey,
                nextKey: builder.scan.completedByKey.count,
                hardLinkClaims: builder.scan.hardLinkClaims,
                minimumAllocatedSizeByNodeID: builder.scan.minimumAllocatedSizeByNodeID,
                targetURL: URL(filePath: "/root", directoryHint: .isDirectory),
                diagnostics: nil,
                callbacks: callbacks
            )
        }
    }

    @Test func progressIsMonotonicAndCompletes() throws {
        let builder = ScanBuilder(seed: 777)
        builder.buildDir("/root", depth: 0, maxDepth: 6)

        var fractions: [Double] = []
        let callbacks = ScanTreeAssembler.Callbacks(progress: { fractions.append($0) })
        _ = try ScanTreeAssembler.assemble(
            completedByKey: builder.scan.completedByKey,
            childrenKeysByKey: builder.scan.childrenKeysByKey,
            nextKey: builder.scan.completedByKey.count,
            hardLinkClaims: builder.scan.hardLinkClaims,
            minimumAllocatedSizeByNodeID: builder.scan.minimumAllocatedSizeByNodeID,
            targetURL: URL(filePath: "/root", directoryHint: .isDirectory),
            diagnostics: nil,
            callbacks: callbacks
        )
        #expect(!fractions.isEmpty)
        #expect(fractions == fractions.sorted())          // non-decreasing
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1.0 })
        #expect(fractions.last == 1.0)
    }

    @Test func forcedDuplicateIDEngagesLegacyFallback() throws {
        // Same id under two different parents: the fast path materializes both,
        // NodeIDIndex.building returns nil, and the fallback yields the legacy
        // result (dedup + warning).
        func meta(_ readable: Bool = true) -> NodeMetadata {
            NodeMetadata(
                isDirectory: true, isPackage: false, isSymbolicLink: false,
                logicalSize: 0, allocatedSize: 0, lastModified: nil,
                isReadable: readable, volumeUsedCapacity: nil, fileIdentity: nil, linkCount: 1
            )
        }
        let dup = makeTestFileNode(id: "/dup", name: "dup", size: 10)
        let completed: [ScanEngine.CompletedDirScan?] = [
            .init(node: nil, metadata: meta(), url: URL(filePath: "/root", directoryHint: .isDirectory), isTraversable: true, depth: 0),
            .init(node: nil, metadata: meta(), url: URL(filePath: "/root/A", directoryHint: .isDirectory), isTraversable: true, depth: 1),
            .init(node: nil, metadata: meta(), url: URL(filePath: "/root/B", directoryHint: .isDirectory), isTraversable: true, depth: 1),
            .init(node: dup, metadata: meta(), url: dup.url, isTraversable: false, depth: 2),
            .init(node: dup, metadata: meta(), url: dup.url, isTraversable: false, depth: 2),
        ]
        let children: [[Int]] = [[1, 2], [3], [4], [], []]

        var fastWarnings: [ScanWarning] = []
        let fast = try ScanTreeAssembler.assemble(
            completedByKey: completed, childrenKeysByKey: children, nextKey: 5,
            hardLinkClaims: [], minimumAllocatedSizeByNodeID: [:],
            targetURL: URL(filePath: "/root", directoryHint: .isDirectory), diagnostics: nil,
            callbacks: ScanTreeAssembler.Callbacks(warning: { fastWarnings.append($0) })
        )
        var legacyWarnings: [ScanWarning] = []
        let legacy = try ScanTreeAssembler.legacyAssemble(
            completedByKey: completed, childrenKeysByKey: children, nextKey: 5,
            hardLinkClaims: [], minimumAllocatedSizeByNodeID: [:],
            targetURL: URL(filePath: "/root", directoryHint: .isDirectory), diagnostics: nil,
            callbacks: ScanTreeAssembler.Callbacks(warning: { legacyWarnings.append($0) })
        )

        #expect(!fastWarnings.isEmpty)             // fallback surfaced the warning
        #expect(fastWarnings.count == legacyWarnings.count)
        Self.assertStoresEqual(fast, legacy)
    }
}
