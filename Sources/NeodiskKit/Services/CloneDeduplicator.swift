//
//  CloneDeduplicator.swift
//  Neodisk
//
//  APFS clone deduplication, the sibling of HardLinkDeduplicator: files in
//  the same clone family share on-disk blocks, so counting every member at
//  full allocated size over-counts real usage — the map's items can then sum
//  past the volume's Finder-reported used space and swallow the hidden-space
//  figure. The deterministic first member (path order, like hard links)
//  keeps its full size; every other member is charged only its private
//  (unshared) bytes, ATTR_CMNEXT_PRIVATESIZE, which traversal reads for
//  every member as it lists the member's folder (fetched here only for a
//  record that lacks it) and which stays stamped in the records so cached
//  snapshots rebalance without the volume mounted. Diverged clones can be slightly
//  under-counted; the residual surfaces as hidden space, never as a
//  negative. A summarized directory (package, auto-summarized folder) has no
//  file records, so its `summarizedClones` tallies stand in for its members:
//  it is charged for each member it doesn't keep.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

nonisolated enum CloneDeduplicator {
    /// Fetches a file's private (unshared) byte count. Injectable so tests
    /// and offline rebalances run without syscalls; nil means unknown and
    /// charges the member zero — the conservative direction (the residual
    /// lands in hidden space). `Sendable` so the parallel fetch can call it
    /// across workers.
    typealias PrivateSizeProvider = @Sendable (_ path: String) -> Int64?

    /// The real provider: one getattrlist(2) for ATTR_CMNEXT_PRIVATESIZE.
    /// Called only for duplicate clone-family members, never in scan hot
    /// loops.
    nonisolated static func systemPrivateSize(path: String) -> Int64? {
        #if canImport(Darwin)
        ScanSyscallTally.recordCloneGetattr(count: 1)
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = UInt32(bitPattern: ATTR_CMNEXT_PRIVATESIZE)

        // returned length (u32) + off_t, padded to 4-byte boundaries.
        var buffer = [UInt8](repeating: 0, count: 16)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            path.withCString { cPath in
                getattrlist(cPath, &request, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
            }
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returnedLength = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard returnedLength >= 12 else { return nil }
            return max(raw.loadUnaligned(fromByteOffset: 4, as: Int64.self), 0)
        }
        #else
        // Clone families are an APFS attribute; other platforms' readers
        // never record `cloneInfo`, so nothing reaches this pass.
        return nil
        #endif
    }

    /// Applies clone deduplication to the finalize handoff's mutable tree
    /// arrays. Runs after hard-link deduplication; the two compose because
    /// this pass only ever lowers a member's current allocated size to its
    /// private size (idempotent, order-stable).
    ///
    /// The per-member private-size reads (`getattrlist`) are independent and
    /// I/O-bound, and on clone-saturated volumes they dominate finalize
    /// (~45s on a 1.5M-node home dir). They are fetched concurrently over
    /// disjoint result slots, then the charges are applied in the original
    /// sequential order so the store stays byte-identical to the serial pass.
    nonisolated static func applyDeduplication(
        nodes: inout [FileNodeRecord],
        parentIndices: [Int32],
        childStarts: [Int32],
        childSlots: inout [Int32],
        indexByID: NodeIDIndex,
        privateSizeProvider: PrivateSizeProvider = systemPrivateSize,
        cancellationCheck: () throws -> Void = {},
        progress: (_ fraction: Double) -> Void = { _ in }
    ) rethrows {
        let groupSince = ScanProfile.now()
        let members = try familyMembers(of: nodes, families: nil, cancellationCheck: cancellationCheck)
        ScanProfile.end(.cloneGroup, since: groupSince, count: members.byFamily.count)
        let orderSince = ScanProfile.now()

        // Every family's non-first members (by path, then id) are the ones
        // charged. Charges are independent per member, so flattening the
        // families into one list keeps the output byte-identical regardless of
        // family iteration order.
        var chargedIndices: [Int32] = []
        var summaryCharges: SummaryCharges = [:]
        for family in members.byFamily.values {
            // A lone file has nothing to share with.
            if family.count == 1, family[0].family < 0 { continue }
            for (position, member) in ordered(family, in: nodes, summaryPaths: members.summaryPaths).enumerated() {
                if member.family >= 0 {
                    recordSummaryCharge(of: member, holdsFirstMember: position == 0, in: nodes, into: &summaryCharges)
                } else if position > 0 {
                    chargedIndices.append(member.index)
                }
            }
        }
        ScanProfile.end(.cloneOrder, since: orderSince, count: chargedIndices.count)
        var changedIndices = applySummaryCharges(summaryCharges, to: &nodes)
        guard !chargedIndices.isEmpty || !changedIndices.isEmpty else { return }
        let applySince = ScanProfile.now()
        defer { ScanProfile.end(.cloneApply, since: applySince) }

        // Resolve each charged member's private size: the stamped figure when
        // present, otherwise a getattrlist read. The reads run concurrently
        // (bounded, disjoint slots), cancellation is polled between batches.
        let stampedPrivateSizes = chargedIndices.map { nodes[Int($0)].cloneInfo?.privateSize }
        // Traversal stamps every member it reads, so a fresh scan has nothing
        // to fetch; only older snapshots and single-item metadata do.
        let needsFetch = stampedPrivateSizes.contains { $0 == nil }
        let chargedPaths = needsFetch ? chargedIndices.map { nodes[Int($0)].path } : []
        var resolvedPrivateSizes = needsFetch
            ? [Int64?](repeating: nil, count: chargedIndices.count)
            : stampedPrivateSizes
        let workerLimit = ScanConcurrencyPolicy.cloneMetadataFetchWorkerLimit()
        let batchSize = 4_096
        var batchStart = needsFetch ? 0 : chargedIndices.count
        if !needsFetch {
            progress(1)
        }
        while batchStart < chargedIndices.count {
            try cancellationCheck()
            let rangeStart = batchStart
            let rangeEnd = min(batchStart + batchSize, chargedIndices.count)
            resolvedPrivateSizes.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let resolvedOut = buffer
                let pathsIn = chargedPaths
                let stampedIn = stampedPrivateSizes
                let provider = privateSizeProvider
                let batchCount = rangeEnd - rangeStart
                let workers = min(workerLimit, batchCount)
                let perWorker = (batchCount + workers - 1) / workers
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let start = min(rangeStart + worker * perWorker, rangeEnd)
                    let end = min(start + perWorker, rangeEnd)
                    for i in start..<end {
                        resolvedOut[i] = stampedIn[i] ?? provider(pathsIn[i])
                    }
                }
            }
            batchStart = rangeEnd
            // The fetch loop is the phase's cost on clone-heavy volumes; the
            // charge/rebuild tail is fast, so batch completion is the honest
            // progress signal.
            progress(Double(rangeEnd) / Double(chargedIndices.count))
        }

        // Apply the charges sequentially, in the original order.
        for (offset, index) in chargedIndices.enumerated() {
            let node = nodes[Int(index)]
            let privateSize = resolvedPrivateSizes[offset]
            let charged = min(node.allocatedSize, max(privateSize ?? 0, 0))
            guard charged != node.allocatedSize || node.cloneInfo?.privateSize == nil else { continue }
            nodes[Int(index)] = node.replacingAllocatedSize(
                charged,
                // Stamp the fetched figure so cached snapshots
                // rebalance offline with the same answer.
                cloneInfo: node.cloneInfo?.privateSize == privateSize
                    ? CloneInfo??.none
                    : .some(node.cloneInfo?.withPrivateSize(privateSize ?? 0))
            )
            if charged != node.allocatedSize {
                changedIndices.insert(index)
            }
        }

        let rebuildSince = ScanProfile.now()
        defer { ScanProfile.end(.cloneRebuild, since: rebuildSince, count: changedIndices.count) }
        AncestorRebuilder.rebuildAffectedAncestors(
            of: changedIndices,
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            cancellationCheck: {}
        )
    }

    /// Re-derives clone deduplication from the store's own records after
    /// subtree mutations — the sibling of
    /// `HardLinkDeduplicator.rebalancedStore`, run right after it so a
    /// removed or replaced first member hands the family's full size to the
    /// next survivor. Offline-safe: uses only the private sizes stamped
    /// into the records at scan time.
    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        families: Set<CloneFamilyKey>? = nil,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        if let families, families.isEmpty { return store }
        let members = try familyMembers(
            of: store.storage.nodes,
            families: families,
            cancellationCheck: cancellationCheck
        )
        // No early-out on families of one: a family shrunk by a subtree
        // removal still needs its surviving member restored to full size.
        guard !members.byFamily.isEmpty else { return store }

        return try AncestorRebuilder.rebalancedStore(store, cancellationCheck: cancellationCheck) { nodes in
            var changedIndices: Set<Int32> = []
            var summaryCharges: SummaryCharges = [:]
            for family in members.byFamily.values {
                try cancellationCheck()
                for (position, member) in ordered(family, in: nodes, summaryPaths: members.summaryPaths).enumerated() {
                    if member.family >= 0 {
                        recordSummaryCharge(of: member, holdsFirstMember: position == 0, in: nodes, into: &summaryCharges)
                        continue
                    }
                    let index = member.index
                    let node = nodes[Int(index)]
                    if position == 0 {
                        // A subtree removal can promote a previously-charged
                        // member to first; restore it to full size so the
                        // family's shared blocks stay counted exactly once.
                        // Never touch hard-link-managed nodes (the pass before
                        // this one owns their sizes), and only undo a charge
                        // this deduplicator made (stamped privateSize).
                        let isHardLinkManaged = node.linkCount > 1 && node.fileIdentity != nil
                        if !isHardLinkManaged,
                           node.cloneInfo?.privateSize != nil,
                           node.allocatedSize != node.unduplicatedAllocatedSize {
                            nodes[Int(index)] = node.replacingAllocatedSize(node.unduplicatedAllocatedSize)
                            changedIndices.insert(index)
                        }
                        continue
                    }
                    let charged = min(node.allocatedSize, max(node.cloneInfo?.privateSize ?? 0, 0))
                    guard charged != node.allocatedSize else { continue }
                    nodes[Int(index)] = node.replacingAllocatedSize(charged)
                    changedIndices.insert(index)
                }
            }
            changedIndices.formUnion(applySummaryCharges(summaryCharges, to: &nodes))
            return changedIndices
        }
    }

    /// One member of a clone family: a file record, or a summarized
    /// directory's tally of the family (`family` indexes its
    /// `summarizedClones.families`; -1 for a file).
    private struct Member {
        let index: Int32
        let family: Int32
    }

    /// Each family's members, limited to `families` when given, plus each
    /// summarized directory's sort key (see `ordered`).
    private struct FamilyMembers {
        var byFamily: [CloneFamilyKey: [Member]] = [:]
        var summaryPaths: [Int32: String] = [:]
    }

    private static func familyMembers(
        of nodes: [FileNodeRecord],
        families: Set<CloneFamilyKey>?,
        cancellationCheck: () throws -> Void
    ) rethrows -> FamilyMembers {
        var members = FamilyMembers()
        for (offset, node) in nodes.enumerated() {
            if offset.isMultiple(of: 4_096) {
                try cancellationCheck()
            }
            if node.isDirectory {
                guard let summarized = node.summarizedClones else { continue }
                var isMember = false
                for (family, tally) in summarized.families.enumerated() {
                    if let families, !families.contains(tally.familyKey) { continue }
                    members.byFamily[tally.familyKey, default: []]
                        .append(Member(index: Int32(offset), family: Int32(family)))
                    isMember = true
                }
                if isMember {
                    members.summaryPaths[Int32(offset)] = node.path + "/"
                }
            } else if let cloneInfo = node.cloneInfo, !node.isSymbolicLink, !node.isSynthetic {
                let familyKey = cloneInfo.familyKey
                if let families, !families.contains(familyKey) { continue }
                members.byFamily[familyKey, default: []].append(Member(index: Int32(offset), family: -1))
            }
        }
        return members
    }

    /// A family's members in charge order (`SharedSizeDeduplication.precedes`).
    /// A summarized directory's members sort as its path plus "/": they live
    /// below it, so after it and before a sibling whose name extends its own.
    private static func ordered(
        _ members: [Member],
        in nodes: [FileNodeRecord],
        summaryPaths: [Int32: String]
    ) -> [Member] {
        guard members.count > 1 else { return members }
        guard members.contains(where: { $0.family >= 0 }) else {
            return members.sorted { SharedSizeDeduplication.precedes(nodes[Int($0.index)], nodes[Int($1.index)]) }
        }
        let keyed: [(path: String, id: String, member: Member)] = members.map { member in
            let node = nodes[Int(member.index)]
            let path = member.family >= 0 ? summaryPaths[member.index] ?? node.path + "/" : node.path
            return (path, node.id, member)
        }
        let sorted = keyed.sorted { lhs, rhs in
            lhs.path == rhs.path ? lhs.id < rhs.id : lhs.path < rhs.path
        }
        return sorted.map(\.member)
    }

    /// New charges per summarized directory (node index) and family offset.
    private typealias SummaryCharges = [Int32: [Int32: Int64]]

    private static func recordSummaryCharge(
        of member: Member,
        holdsFirstMember: Bool,
        in nodes: [FileNodeRecord],
        into charges: inout SummaryCharges
    ) {
        guard let tally = nodes[Int(member.index)].summarizedClones?.families[Int(member.family)] else { return }
        charges[member.index, default: [:]][member.family] = tally.charge(holdsFirstMember: holdsFirstMember)
    }

    /// Moves each summarized directory by the change in its families'
    /// charges and stamps the new ones; returns the directories it resized.
    private static func applySummaryCharges(
        _ charges: SummaryCharges,
        to nodes: inout [FileNodeRecord]
    ) -> Set<Int32> {
        var changedIndices: Set<Int32> = []
        for (index, chargeByFamily) in charges {
            let node = nodes[Int(index)]
            guard var families = node.summarizedClones?.families else { continue }
            var delta: Int64 = 0
            for (family, charge) in chargeByFamily where families[Int(family)].charge != charge {
                delta += charge - families[Int(family)].charge
                families[Int(family)] = families[Int(family)].withCharge(charge)
            }
            guard families != node.summarizedClones?.families else { continue }
            let allocatedSize = max(0, node.allocatedSize - delta)
            nodes[Int(index)] = node.replacingAllocatedSize(
                allocatedSize,
                summarizedClones: .some(SummarizedClones(families: families))
            )
            if allocatedSize != node.allocatedSize {
                changedIndices.insert(index)
            }
        }
        return changedIndices
    }
}

/// The two shared-block deduplication passes in their required order —
/// hard links first (restores claim owners from unduplicated sizes), then
/// clones (only ever lowers current sizes). Subtree mutations call this
/// instead of the individual passes.
nonisolated enum SharedSizeDeduplication {
    /// The shared-block families an edit can have changed: those with a
    /// member in a removed or replaced subtree, or in an inserted one. Every
    /// other family kept its members and records, so it is still balanced
    /// exactly as before the edit and the rebalance can leave it alone.
    struct Scope {
        var cloneFamilies = Set<CloneFamilyKey>()
        var hardLinkIdentities = Set<FileIdentity>()

        mutating func include(_ node: FileNodeRecord) {
            for tally in node.summarizedClones?.families ?? [] {
                cloneFamilies.insert(tally.familyKey)
            }
            guard !node.isDirectory, !node.isSymbolicLink, !node.isSynthetic else { return }
            if let cloneInfo = node.cloneInfo {
                cloneFamilies.insert(cloneInfo.familyKey)
            }
            if node.linkCount > 1, let identity = node.fileIdentity {
                hardLinkIdentities.insert(identity)
            }
        }
    }

    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        scope: Scope? = nil,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        let hardLinked = try ScanTiming.measure("rescan.splice.rebalance.hardLinks") {
            try HardLinkDeduplicator.rebalancedStore(
                store,
                identities: scope?.hardLinkIdentities,
                cancellationCheck: cancellationCheck
            )
        }
        return try ScanTiming.measure("rescan.splice.rebalance.clones") {
            try CloneDeduplicator.rebalancedStore(
                hardLinked,
                families: scope.map { scope in
                    // The hard-link pass may have resized a member of an
                    // otherwise untouched clone family: that family is
                    // touched too.
                    var families = scope.cloneFamilies
                    guard !scope.hardLinkIdentities.isEmpty else { return families }
                    for node in hardLinked.storage.nodes where node.linkCount > 1 {
                        if let cloneInfo = node.cloneInfo, let identity = node.fileIdentity,
                           scope.hardLinkIdentities.contains(identity) {
                            families.insert(cloneInfo.familyKey)
                        }
                    }
                    return families
                },
                cancellationCheck: cancellationCheck
            )
        }
    }

    /// The deterministic tie-break both passes charge on: order shared-block
    /// members by path, then by node id. The first member keeps its full size;
    /// every other member is charged. One definition for the hard-link and
    /// clone passes (and their store-rebalance twins).
    nonisolated static func precedes(_ a: FileNodeRecord, _ b: FileNodeRecord) -> Bool {
        a.path == b.path ? a.id < b.id : a.path < b.path
    }

    /// Claim-typed twin of the node comparator above: hard-link claims tie-break
    /// on the claim's owner node id.
    nonisolated static func precedes(_ a: HardLinkClaim, _ b: HardLinkClaim) -> Bool {
        a.path == b.path ? a.ownerNodeID < b.ownerNodeID : a.path < b.path
    }
}
