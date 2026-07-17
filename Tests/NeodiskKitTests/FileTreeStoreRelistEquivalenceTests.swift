import Foundation
import Testing
@testable import NeodiskKit

/// Proves the numeric root-relist splice (`numericApplyEdits`, via
/// `applyingRootRelist`) produces a store semantically identical to the
/// dictionary oracle (`legacyApplyingRootRelist`) across randomized trees with
/// mixed edits: direct children removed, brand-new children inserted, existing
/// subtrees replaced, and the root's own record refreshed — all in one pass,
/// including hard links and clone families crossing the edit boundaries, which
/// exercise the shared-size rebalance both paths finish with.
///
/// Equality is semantic (per-id records, per-parent ordered child lists, parent
/// links, aggregate stats), not raw-array: the legacy path rebuilds in
/// freshly-sorted preorder while the numeric path preserves positions and fixes
/// child slots, so layouts legitimately differ while the store contract must not.
@Suite struct FileTreeStoreRelistEquivalenceTests {
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
        var openHardLinkIdentities: [FileIdentity] = []
        var openCloneFamilies: [CloneInfo] = []

        init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }

        func tieProneSize() -> Int64 {
            let choices: [Int64] = [0, 4096, 4096, 4096, 8192, 8192, 12288, 100_000]
            return choices[int(0...(choices.count - 1))]
        }

        func file(path: String) -> FileNodeRecord {
            var identity: FileIdentity?
            var linkCount: UInt64 = 1
            var cloneInfo: CloneInfo?
            if chance(0.10) {
                if let existing = openHardLinkIdentities.last, chance(0.6) {
                    identity = existing
                } else {
                    identity = FileIdentity(device: 1, inode: hardLinkIdentitySeed)
                    hardLinkIdentitySeed += 1
                    openHardLinkIdentities.append(identity!)
                }
                linkCount = 2
            } else if chance(0.10) {
                if let existing = openCloneFamilies.last, chance(0.6) {
                    cloneInfo = existing
                } else {
                    cloneInfo = CloneInfo(device: 1, cloneID: cloneIDSeed, refCount: 3, privateSize: Int64(int(0...2048)))
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

        func directory(path: String, depth: Int, childrenByID: inout [String: [FileNodeRecord]]) -> FileNodeRecord {
            var children: [FileNodeRecord] = []
            for i in 0..<int(0...4) { children.append(file(path: "\(path)/f\(i)")) }
            if depth > 0 {
                for i in 0..<int(0...3) {
                    children.append(directory(path: "\(path)/d\(i)", depth: depth - 1, childrenByID: &childrenByID))
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
        x.id == y.id && x.path == y.path && x.name == y.name
            && x.isDirectory == y.isDirectory && x.isSymbolicLink == y.isSymbolicLink
            && x.allocatedSize == y.allocatedSize
            && x.unduplicatedAllocatedSize == y.unduplicatedAllocatedSize
            && x.logicalSize == y.logicalSize
            && x.descendantFileCount == y.descendantFileCount
            && x.lastModified == y.lastModified
            && x.fileIdentity == y.fileIdentity && x.linkCount == y.linkCount
            && x.isPackage == y.isPackage && x.isAccessible == y.isAccessible
            && x.isSelfAccessible == y.isSelfAccessible && x.isSynthetic == y.isSynthetic
            && x.isAutoSummarized == y.isAutoSummarized
            && x.cloudOnlyLogicalSize == y.cloudOnlyLogicalSize && x.cloneInfo == y.cloneInfo
    }

    private static func assertSemanticallyEqual(_ numeric: FileTreeStore, _ legacy: FileTreeStore) {
        #expect(numeric.rootID == legacy.rootID)
        #expect(numeric.nodeCount == legacy.nodeCount)
        for id in legacy.indexedNodeIDs() {
            guard let n = numeric.node(id: id), let l = legacy.node(id: id) else {
                Issue.record("node \(id) missing from numeric store"); return
            }
            if !recordsEqual(n, l) { Issue.record("record for \(id) differs: \(n) vs \(l)"); return }
            if numeric.parent(of: id)?.id != legacy.parent(of: id)?.id {
                Issue.record("parent of \(id) differs"); return
            }
            if numeric.children(of: id).map(\.id) != legacy.children(of: id).map(\.id) {
                Issue.record("children of \(id) differ"); return
            }
        }
        let a = numeric.aggregateStats, b = legacy.aggregateStats
        #expect(a.totalAllocatedSize == b.totalAllocatedSize)
        #expect(a.totalLogicalSize == b.totalLogicalSize)
        #expect(a.fileCount == b.fileCount)
        #expect(a.directoryCount == b.directoryCount)
    }

    /// Picks up to `count` non-ancestor directory targets, none under a removed
    /// direct child of the root.
    private static func pickReplacements(
        in store: FileTreeStore,
        excludingUnder removed: Set<String>,
        count: Int,
        builder: TreeBuilder
    ) -> [String] {
        let rootID = store.rootID
        let directoryIDs = store.indexedNodeIDs(excludingRoot: true).filter {
            store.node(id: $0)?.isDirectory == true
                && !removed.contains($0)
                && !store.hasAncestor(in: removed, of: $0)
                && $0 != rootID
        }
        guard !directoryIDs.isEmpty else { return [] }
        var picked: [String] = []
        for _ in 0..<(count * 5) where picked.count < count {
            let candidate = directoryIDs[builder.int(0...(directoryIDs.count - 1))]
            let overlaps = picked.contains {
                candidate == $0 || candidate.hasPrefix($0 + "/") || $0.hasPrefix(candidate + "/")
            }
            if !overlaps { picked.append(candidate) }
        }
        return picked
    }

    @Test func randomizedRootRelistsMatchLegacyOracle() throws {
        for seed: UInt64 in 1...24 {
            let builder = TreeBuilder(seed: seed)
            let baseline = builder.store(rootPath: "/root", depth: 4)
            let rootID = baseline.rootID
            let directChildren = baseline.children(of: rootID).map(\.id)

            // Remove some direct children.
            var removals: [String] = []
            for id in directChildren where builder.chance(0.25) { removals.append(id) }
            let removedSet = Set(removals)

            // Insert some brand-new direct children.
            var insertions: [FileTreeStore] = []
            for i in 0..<builder.int(0...3) {
                insertions.append(builder.store(rootPath: "/root/inserted-\(seed)-\(i)", depth: builder.int(0...2)))
            }

            // Replace some existing subtrees (not under a removed child).
            let targets = Self.pickReplacements(
                in: baseline, excludingUnder: removedSet,
                count: builder.int(0...4), builder: builder
            )
            let replacements: [(id: String, store: FileTreeStore)] = targets.map {
                (id: $0, store: builder.store(rootPath: $0, depth: builder.int(0...2)))
            }

            // Optionally refresh the root record.
            let rootOverride: FileNodeRecord? = builder.chance(0.5)
                ? baseline.root.replacingLastModified(Date(timeIntervalSince1970: Double(seed) * 1000))
                : nil

            // Skip the degenerate all-empty case (nothing to prove).
            if removals.isEmpty && insertions.isEmpty && replacements.isEmpty && rootOverride == nil {
                continue
            }

            let numericOutcome = try baseline.numericApplyEdits(
                replacements: replacements,
                removingSubtreeIDs: removals,
                insertions: insertions.map { FileTreeStore.SubtreeInsertion(parentID: rootID, store: $0) },
                rootRecordOverride: rootOverride,
                cancellationCheck: {}
            )
            guard case .spliced(let numeric) = numericOutcome else {
                Issue.record("seed \(seed): numeric path declined a supported relist (\(numericOutcome))")
                return
            }
            let legacy = try #require(try baseline.legacyApplyingRootRelist(
                refreshedRootRecord: rootOverride,
                removingChildren: removals,
                insertingChildren: insertions,
                replacements: replacements,
                cancellationCheck: {}
            ))
            Self.assertSemanticallyEqual(numeric, legacy)

            // Membership actually changed.
            for removed in removals { #expect(numeric.node(id: removed) == nil) }
            for inserted in insertions {
                #expect(numeric.node(id: inserted.rootID) != nil)
                #expect(numeric.parent(of: inserted.rootID)?.id == rootID)
            }
            if let rootOverride {
                #expect(numeric.root.lastModified == rootOverride.lastModified)
            }
        }
    }

    @Test func pureRemovalMatchesLegacy() throws {
        let builder = TreeBuilder(seed: 101)
        let baseline = builder.store(rootPath: "/root", depth: 4)
        let child = try #require(baseline.children(of: baseline.rootID).first(where: { $0.isDirectory })?.id)

        guard case .spliced(let numeric) = try baseline.numericApplyEdits(
            replacements: [], removingSubtreeIDs: [child], insertions: [],
            rootRecordOverride: nil, cancellationCheck: {}
        ) else { Issue.record("declined pure removal"); return }
        let legacy = try #require(try baseline.legacyApplyingRootRelist(
            refreshedRootRecord: nil, removingChildren: [child],
            insertingChildren: [], replacements: [], cancellationCheck: {}
        ))
        Self.assertSemanticallyEqual(numeric, legacy)
        #expect(numeric.node(id: child) == nil)
    }

    @Test func pureInsertionMatchesLegacy() throws {
        let builder = TreeBuilder(seed: 202)
        let baseline = builder.store(rootPath: "/root", depth: 3)
        let insertion = builder.store(rootPath: "/root/fresh", depth: 2)

        guard case .spliced(let numeric) = try baseline.numericApplyEdits(
            replacements: [], removingSubtreeIDs: [],
            insertions: [FileTreeStore.SubtreeInsertion(parentID: baseline.rootID, store: insertion)],
            rootRecordOverride: nil, cancellationCheck: {}
        ) else { Issue.record("declined pure insertion"); return }
        let legacy = try #require(try baseline.legacyApplyingRootRelist(
            refreshedRootRecord: nil, removingChildren: [],
            insertingChildren: [insertion], replacements: [], cancellationCheck: {}
        ))
        Self.assertSemanticallyEqual(numeric, legacy)
        #expect(numeric.node(id: "/root/fresh") != nil)
    }

    @Test func repeatedRelistsStayEquivalent() throws {
        // A relist's output feeds the next rescan's baseline; run generations.
        let builder = TreeBuilder(seed: 303)
        var numericStore = builder.store(rootPath: "/root", depth: 4)
        var legacyStore = numericStore
        for gen in 0..<3 {
            let rootID = numericStore.rootID
            let directChildren = numericStore.children(of: rootID).map(\.id)
            let removals = directChildren.filter { _ in builder.chance(0.2) }
            let insertion = builder.store(rootPath: "/root/gen\(gen)", depth: 1)
            let targets = Self.pickReplacements(
                in: numericStore, excludingUnder: Set(removals), count: 2, builder: builder
            )
            let replacements: [(id: String, store: FileTreeStore)] = targets.map {
                (id: $0, store: builder.store(rootPath: $0, depth: 1))
            }
            guard case .spliced(let nextNumeric) = try numericStore.numericApplyEdits(
                replacements: replacements, removingSubtreeIDs: removals,
                insertions: [FileTreeStore.SubtreeInsertion(parentID: rootID, store: insertion)],
                rootRecordOverride: nil, cancellationCheck: {}
            ) else { Issue.record("gen \(gen): declined"); return }
            numericStore = nextNumeric
            legacyStore = try #require(try legacyStore.legacyApplyingRootRelist(
                refreshedRootRecord: nil, removingChildren: removals,
                insertingChildren: [insertion], replacements: replacements, cancellationCheck: {}
            ))
            Self.assertSemanticallyEqual(numericStore, legacyStore)
        }
    }

    @Test func cancellationPropagates() {
        let builder = TreeBuilder(seed: 7)
        let baseline = builder.store(rootPath: "/root", depth: 3)
        #expect(throws: CancellationError.self) {
            _ = try baseline.numericApplyEdits(
                replacements: [], removingSubtreeIDs: [],
                insertions: [FileTreeStore.SubtreeInsertion(
                    parentID: baseline.rootID,
                    store: builder.store(rootPath: "/root/x", depth: 1)
                )],
                rootRecordOverride: nil,
                cancellationCheck: { throw CancellationError() }
            )
        }
    }
}
