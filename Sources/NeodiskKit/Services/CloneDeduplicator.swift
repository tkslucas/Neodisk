// APFS clones share blocks, so the first member (path order) keeps its full size and the rest are charged
// only their private bytes; otherwise the map sums past used space. Summarized dirs charge via their tallies.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

nonisolated enum CloneDeduplicator {
    /// Nil means unknown and charges zero, the conservative direction (the residual lands in hidden space).
    typealias PrivateSizeProvider = @Sendable (_ path: String) -> Int64?

    /// Called only for duplicate clone-family members, never in scan hot loops.
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

    /// Only lowers sizes, so it composes with hard-link dedup. Reads run concurrently (~45s serially on 1.5M
    /// nodes), then charges apply in sequential order to stay byte-identical.
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

        // Charges are independent per member, so flattening families keeps the output independent of
        // iteration order.
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

        // Stamped private size when present, else a bounded concurrent getattrlist read.
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
            // The fetch loop is the phase's real cost, so batch completion is the honest progress signal.
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

    /// Run after `HardLinkDeduplicator.rebalancedStore` so a removed first member hands the full size on.
    /// Offline-safe: uses only the private sizes stamped at scan time.
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
                        // A removal can promote a charged member to first: restore its size. Skip
                        // hard-link-managed nodes and only undo charges this pass made (stamped privateSize).
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

    /// `family` indexes the directory's `summarizedClones.families`; -1 for a file.
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

    /// A summarized directory sorts as its path plus "/": after itself, before a sibling whose name extends it.
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

/// Hard links first (restores owners from unduplicated sizes), then clones (only lowers sizes).
nonisolated enum SharedSizeDeduplication {
    /// Families with a member in a removed, replaced or inserted subtree; every other one is still balanced.
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
                    // The hard-link pass may have resized a member of an untouched clone family, so it counts
                    // as touched.
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

    /// First by path, then id, keeps its full size; one definition for both passes and their rebalance twins.
    nonisolated static func precedes(_ a: FileNodeRecord, _ b: FileNodeRecord) -> Bool {
        a.path == b.path ? a.id < b.id : a.path < b.path
    }

    /// Claim-typed twin of the node comparator above: hard-link claims tie-break
    /// on the claim's owner node id.
    nonisolated static func precedes(_ a: HardLinkClaim, _ b: HardLinkClaim) -> Bool {
        a.path == b.path ? a.ownerNodeID < b.ownerNodeID : a.path < b.path
    }
}
