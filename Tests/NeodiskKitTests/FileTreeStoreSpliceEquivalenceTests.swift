import Foundation
import Testing
@testable import NeodiskKit

/// Proves the numeric splice (`numericReplacingSubtrees`) produces a store
/// semantically identical to the dictionary oracle
/// (`legacyReplacingSubtrees`) across randomized trees, targets, and
/// replacement stores — including hard links and clone families crossing the
/// splice boundary, which exercise the shared-size rebalance both paths
/// finish with.
///
/// Equality is semantic (per-id records, per-parent ordered child lists,
/// parent links, aggregate stats), not raw-array: the legacy path rebuilds
/// its arrays in freshly-sorted preorder while the numeric path preserves
/// positions and fixes child slots, so layouts legitimately differ while the
/// store contract (`children(of:)` order, lookups, totals) must not.
@Suite struct FileTreeStoreSpliceEquivalenceTests {
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

    private final class TreeBuilder {
        var rng: SeededGenerator
        var hardLinkIdentitySeed: UInt64 = 1
        var cloneIDSeed: UInt64 = 1
        /// Open hard-link/clone families that later files may join, so
        /// members land on both sides of splice boundaries.
        var openHardLinkIdentities: [FileIdentity] = []
        var openCloneFamilies: [CloneInfo] = []

        init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

        func int(_ range: ClosedRange<Int>) -> Int {
            Int.random(in: range, using: &rng)
        }

        func chance(_ probability: Double) -> Bool {
            Double.random(in: 0..<1, using: &rng) < probability
        }

        /// Tie-prone sizes mirror 4KB quantization on real volumes.
        func tieProneSize() -> Int64 {
            let choices: [Int64] = [0, 4096, 4096, 4096, 8192, 8192, 12288, 100_000]
            return choices[int(0...(choices.count - 1))]
        }

        func file(path: String) -> FileNodeRecord {
            var identity: FileIdentity?
            var linkCount: UInt64 = 1
            var cloneInfo: CloneInfo?
            if chance(0.08) {
                if let existing = openHardLinkIdentities.last, chance(0.6) {
                    identity = existing
                } else {
                    identity = FileIdentity(device: 1, inode: hardLinkIdentitySeed)
                    hardLinkIdentitySeed += 1
                    openHardLinkIdentities.append(identity!)
                }
                linkCount = 2
            } else if chance(0.08) {
                if let existing = openCloneFamilies.last, chance(0.6) {
                    cloneInfo = existing
                } else {
                    cloneInfo = CloneInfo(
                        device: 1,
                        cloneID: cloneIDSeed,
                        refCount: 3,
                        privateSize: Int64(int(0...2048))
                    )
                    cloneIDSeed += 1
                    openCloneFamilies.append(cloneInfo!)
                }
            }
            let size = tieProneSize()
            return FileNodeRecord(
                id: path,
                url: URL(filePath: path),
                name: URL(filePath: path).lastPathComponent,
                isDirectory: false,
                isSymbolicLink: chance(0.04),
                allocatedSize: size,
                logicalSize: size,
                descendantFileCount: 1,
                lastModified: nil,
                fileIdentity: identity,
                linkCount: linkCount,
                isPackage: false,
                isAccessible: !chance(0.03),
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false,
                cloneInfo: cloneInfo
            )
        }

        /// Builds a random directory subtree, filling `childrenByID`, and
        /// returns the directory record (totals derived via
        /// `FileNodeRecord.directory`, same as production builders).
        func directory(
            path: String,
            depth: Int,
            childrenByID: inout [String: [FileNodeRecord]]
        ) -> FileNodeRecord {
            var children: [FileNodeRecord] = []
            let fileCount = int(0...4)
            for i in 0..<fileCount {
                children.append(file(path: "\(path)/f\(i)"))
            }
            if depth > 0 {
                let dirCount = int(0...3)
                for i in 0..<dirCount {
                    children.append(directory(
                        path: "\(path)/d\(i)",
                        depth: depth - 1,
                        childrenByID: &childrenByID
                    ))
                }
            }
            let record = FileNodeRecord.directory(
                id: path,
                url: URL(filePath: path, directoryHint: .isDirectory),
                name: URL(filePath: path).lastPathComponent,
                children: children,
                lastModified: nil,
                isPackage: false,
                isAccessible: true
            )
            childrenByID[path] = children
            return record
        }

        func store(rootPath: String, depth: Int) -> FileTreeStore {
            var childrenByID: [String: [FileNodeRecord]] = [:]
            let root = directory(path: rootPath, depth: depth, childrenByID: &childrenByID)
            return FileTreeStore(root: root, childrenByID: childrenByID)
        }
    }

    private static func recordsEqual(_ x: FileNodeRecord, _ y: FileNodeRecord) -> Bool {
        x.id == y.id
            && x.path == y.path
            && x.name == y.name
            && x.isDirectory == y.isDirectory
            && x.isSymbolicLink == y.isSymbolicLink
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
            && x.cloudOnlyLogicalSize == y.cloudOnlyLogicalSize
            && x.cloneInfo == y.cloneInfo
    }

    private static func assertSemanticallyEqual(_ numeric: FileTreeStore, _ legacy: FileTreeStore) {
        #expect(numeric.rootID == legacy.rootID)
        #expect(numeric.nodeCount == legacy.nodeCount)

        for id in legacy.indexedNodeIDs() {
            guard let numericNode = numeric.node(id: id), let legacyNode = legacy.node(id: id) else {
                Issue.record("node \(id) missing from numeric store")
                return
            }
            if !recordsEqual(numericNode, legacyNode) {
                Issue.record("record for \(id) differs: \(numericNode) vs \(legacyNode)")
                return
            }
            if numeric.parent(of: id)?.id != legacy.parent(of: id)?.id {
                Issue.record("parent of \(id) differs")
                return
            }
            let numericChildren = numeric.children(of: id).map(\.id)
            let legacyChildren = legacy.children(of: id).map(\.id)
            if numericChildren != legacyChildren {
                Issue.record("children of \(id) differ: \(numericChildren) vs \(legacyChildren)")
                return
            }
        }

        let a = numeric.aggregateStats
        let b = legacy.aggregateStats
        #expect(a.totalAllocatedSize == b.totalAllocatedSize)
        #expect(a.totalLogicalSize == b.totalLogicalSize)
        #expect(a.fileCount == b.fileCount)
        #expect(a.directoryCount == b.directoryCount)
        #expect(a.accessibleItemCount == b.accessibleItemCount)
        #expect(a.inaccessibleItemCount == b.inaccessibleItemCount)
    }

    /// Picks up to `count` pairwise non-ancestor directory targets.
    private static func pickTargets(
        in store: FileTreeStore,
        count: Int,
        builder: TreeBuilder
    ) -> [String] {
        let directoryIDs = store.indexedNodeIDs(excludingRoot: true).filter {
            store.node(id: $0)?.isDirectory == true
        }
        guard !directoryIDs.isEmpty else { return [] }
        var picked: [String] = []
        for _ in 0..<(count * 4) where picked.count < count {
            let candidate = directoryIDs[builder.int(0...(directoryIDs.count - 1))]
            let overlaps = picked.contains { existing in
                candidate == existing
                    || candidate.hasPrefix(existing + "/")
                    || existing.hasPrefix(candidate + "/")
            }
            if !overlaps {
                picked.append(candidate)
            }
        }
        return picked
    }

    @Test func randomizedSplicesMatchLegacyOracle() throws {
        for seed: UInt64 in 1...12 {
            let builder = TreeBuilder(seed: seed)
            let baseline = builder.store(rootPath: "/root", depth: 4)
            let targets = Self.pickTargets(
                in: baseline,
                count: builder.int(1...6),
                builder: builder
            )
            guard !targets.isEmpty else { continue }

            let replacements: [(id: String, store: FileTreeStore)] = targets.map { targetID in
                // Rebuild the same path with fresh random content, so ids
                // inside the replaced subtree are reused (allowed) while the
                // subtree's shape and sizes change.
                (id: targetID, store: builder.store(rootPath: targetID, depth: 2))
            }

            let numericOutcome = try baseline.numericReplacingSubtrees(
                replacements,
                cancellationCheck: {}
            )
            guard case .spliced(let numeric) = numericOutcome else {
                Issue.record("seed \(seed): numeric path declined a supported splice")
                return
            }
            let legacy = try #require(try baseline.legacyReplacingSubtrees(
                replacements,
                cancellationCheck: {}
            ))
            Self.assertSemanticallyEqual(numeric, legacy)
        }
    }

    @Test func repeatedSplicesStayEquivalent() throws {
        // Splice output feeds the next rescan's baseline; run three
        // generations through both paths to prove the numeric result is a
        // valid baseline for itself.
        let builder = TreeBuilder(seed: 99)
        var numericStore = builder.store(rootPath: "/root", depth: 4)
        var legacyStore = numericStore
        for _ in 0..<3 {
            let targets = Self.pickTargets(in: numericStore, count: 3, builder: builder)
            guard !targets.isEmpty else { break }
            let replacements: [(id: String, store: FileTreeStore)] = targets.map {
                (id: $0, store: builder.store(rootPath: $0, depth: 2))
            }
            guard case .spliced(let nextNumeric) = try numericStore.numericReplacingSubtrees(
                replacements,
                cancellationCheck: {}
            ) else {
                Issue.record("numeric path declined a supported splice")
                return
            }
            numericStore = nextNumeric
            legacyStore = try #require(try legacyStore.legacyReplacingSubtrees(
                replacements,
                cancellationCheck: {}
            ))
            Self.assertSemanticallyEqual(numericStore, legacyStore)
        }
    }

    @Test func replacementRootWithDifferentIDMatchesLegacy() throws {
        let builder = TreeBuilder(seed: 7)
        let baseline = builder.store(rootPath: "/root", depth: 3)
        let targets = Self.pickTargets(in: baseline, count: 1, builder: builder)
        let targetID = try #require(targets.first)

        let replacement = builder.store(rootPath: "/root/renamed-replacement", depth: 1)
        guard case .spliced(let numeric) = try baseline.numericReplacingSubtrees(
            [(id: targetID, store: replacement)],
            cancellationCheck: {}
        ) else {
            Issue.record("numeric path declined a supported splice")
            return
        }
        let legacy = try #require(try baseline.legacyReplacingSubtrees(
            [(id: targetID, store: replacement)],
            cancellationCheck: {}
        ))
        Self.assertSemanticallyEqual(numeric, legacy)
        #expect(numeric.node(id: targetID) == nil)
        #expect(numeric.node(id: "/root/renamed-replacement") != nil)
    }

    @Test func numericValidationOutcomesMatchLegacyContract() throws {
        let builder = TreeBuilder(seed: 21)
        let baseline = builder.store(rootPath: "/root", depth: 3)
        let replacement = builder.store(rootPath: "/root/anything", depth: 1)

        // Missing target → invalidTarget (public contract: nil).
        var outcome = try baseline.numericReplacingSubtrees(
            [(id: "/root/does-not-exist", store: replacement)],
            cancellationCheck: {}
        )
        guard case .invalidTarget = outcome else {
            Issue.record("missing target should be invalidTarget")
            return
        }

        // Root target → invalidTarget.
        outcome = try baseline.numericReplacingSubtrees(
            [(id: "/root", store: replacement)],
            cancellationCheck: {}
        )
        guard case .invalidTarget = outcome else {
            Issue.record("root target should be invalidTarget")
            return
        }

        // Cancellation propagates.
        #expect(throws: CancellationError.self) {
            _ = try baseline.numericReplacingSubtrees(
                [(id: "/root/d0", store: replacement)],
                cancellationCheck: { throw CancellationError() }
            )
        }
    }
}
