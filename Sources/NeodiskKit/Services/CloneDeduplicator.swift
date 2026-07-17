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
//  (unshared) bytes, fetched lazily via ATTR_CMNEXT_PRIVATESIZE for just
//  those few files and stamped into their records so cached snapshots
//  rebalance without the volume mounted. Diverged clones can be slightly
//  under-counted; the residual surfaces as hidden space, never as a
//  negative.
//

import Darwin
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
        rebuild: HardLinkDeduplicator.AncestorRebuild = HardLinkDeduplicator.numericAncestorRebuild,
        cancellationCheck: () throws -> Void = {},
        progress: (_ fraction: Double) -> Void = { _ in }
    ) rethrows {
        var memberIndicesByFamily: [CloneFamilyKey: [Int32]] = [:]
        for (index, node) in nodes.enumerated() {
            guard let cloneInfo = node.cloneInfo, !node.isDirectory, !node.isSymbolicLink,
                  !node.isSynthetic else { continue }
            memberIndicesByFamily[cloneInfo.familyKey, default: []].append(Int32(index))
        }

        // Every family's non-first members (by path, then id) are the ones
        // charged. Charges are independent per member, so flattening the
        // families into one list keeps the output byte-identical regardless of
        // family iteration order.
        var chargedIndices: [Int32] = []
        for memberIndices in memberIndicesByFamily.values where memberIndices.count > 1 {
            let sorted = memberIndices.sorted { lhs, rhs in
                let lhsNode = nodes[Int(lhs)]
                let rhsNode = nodes[Int(rhs)]
                if lhsNode.path == rhsNode.path { return lhsNode.id < rhsNode.id }
                return lhsNode.path < rhsNode.path
            }
            chargedIndices.append(contentsOf: sorted.dropFirst())
        }
        guard !chargedIndices.isEmpty else { return }

        // Resolve each charged member's private size: the stamped figure when
        // present, otherwise a getattrlist read. The reads run concurrently
        // (bounded, disjoint slots), cancellation is polled between batches.
        let chargedPaths = chargedIndices.map { nodes[Int($0)].path }
        let stampedPrivateSizes = chargedIndices.map { nodes[Int($0)].cloneInfo?.privateSize }
        var resolvedPrivateSizes = [Int64?](repeating: nil, count: chargedIndices.count)
        let workerLimit = ScanConcurrencyPolicy.cloneMetadataFetchWorkerLimit()
        let batchSize = 4_096
        var batchStart = 0
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
        var changedIndices: Set<Int32> = []
        for (offset, index) in chargedIndices.enumerated() {
            let node = nodes[Int(index)]
            let privateSize = resolvedPrivateSizes[offset]
            let charged = min(node.allocatedSize, max(privateSize ?? 0, 0))
            guard charged != node.allocatedSize || node.cloneInfo?.privateSize == nil else { continue }
            nodes[Int(index)] = node.replacingAllocatedSize(
                charged,
                // Stamp the fetched figure so cached snapshots
                // rebalance offline with the same answer.
                cloneInfo: node.cloneInfo?.withPrivateSize(privateSize ?? 0)
            )
            if charged != node.allocatedSize {
                changedIndices.insert(index)
            }
        }

        rebuild(changedIndices, &nodes, parentIndices, childStarts, &childSlots)
    }

    /// Re-derives clone deduplication from the store's own records after
    /// subtree mutations — the sibling of
    /// `HardLinkDeduplicator.rebalancedStore`, run right after it so a
    /// removed or replaced first member hands the family's full size to the
    /// next survivor. Offline-safe: uses only the private sizes stamped
    /// into the records at scan time.
    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        let storage = store.storage
        var memberIndicesByFamily: [CloneFamilyKey: [Int32]] = [:]
        for (offset, node) in storage.nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard let cloneInfo = node.cloneInfo, !node.isDirectory, !node.isSymbolicLink,
                  !node.isSynthetic else { continue }
            memberIndicesByFamily[cloneInfo.familyKey, default: []].append(Int32(offset))
        }
        // No early-out on families of one: a family shrunk by a subtree
        // removal still needs its surviving member restored to full size.
        guard !memberIndicesByFamily.isEmpty else { return store }

        var nodes = storage.nodes
        var childSlots = storage.childSlots
        var changedIndices: Set<Int32> = []
        for memberIndices in memberIndicesByFamily.values {
            try cancellationCheck()
            let sorted = memberIndices.sorted { lhs, rhs in
                let lhsNode = nodes[Int(lhs)]
                let rhsNode = nodes[Int(rhs)]
                if lhsNode.path == rhsNode.path { return lhsNode.id < rhsNode.id }
                return lhsNode.path < rhsNode.path
            }
            // A subtree removal can promote a previously-charged member to
            // first; restore it to full size so the family's shared blocks
            // stay counted exactly once. Never touch hard-link-managed
            // nodes (the pass before this one owns their sizes), and only
            // undo a charge this deduplicator made (stamped privateSize).
            let firstIndex = sorted[0]
            let first = nodes[Int(firstIndex)]
            let firstIsHardLinkManaged = first.linkCount > 1 && first.fileIdentity != nil
            if !firstIsHardLinkManaged,
               first.cloneInfo?.privateSize != nil,
               first.allocatedSize != first.unduplicatedAllocatedSize {
                nodes[Int(firstIndex)] = first.replacingAllocatedSize(first.unduplicatedAllocatedSize)
                changedIndices.insert(firstIndex)
            }
            for index in sorted.dropFirst() {
                let node = nodes[Int(index)]
                let charged = min(node.allocatedSize, max(node.cloneInfo?.privateSize ?? 0, 0))
                guard charged != node.allocatedSize else { continue }
                nodes[Int(index)] = node.replacingAllocatedSize(charged)
                changedIndices.insert(index)
            }
        }

        guard !changedIndices.isEmpty else { return store }

        try HardLinkDeduplicator.rebuildAffectedAncestors(
            of: changedIndices,
            nodes: &nodes,
            parentIndices: storage.parentIndices,
            childStarts: storage.childStarts,
            childSlots: &childSlots,
            cancellationCheck: cancellationCheck
        )

        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: storage.parentIndices,
                childStarts: storage.childStarts,
                childSlots: childSlots,
                indexByID: storage.indexByID,
                // Only node sizes change here, never IDs, so the stored
                // per-node hashes carry over unchanged.
                nodeHashes: storage.nodeHashes
            ),
            rootID: store.rootID
        )
    }
}

/// The two shared-block deduplication passes in their required order —
/// hard links first (restores claim owners from unduplicated sizes), then
/// clones (only ever lowers current sizes). Subtree mutations call this
/// instead of the individual passes.
nonisolated enum SharedSizeDeduplication {
    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        try CloneDeduplicator.rebalancedStore(
            HardLinkDeduplicator.rebalancedStore(store, cancellationCheck: cancellationCheck),
            cancellationCheck: cancellationCheck
        )
    }
}
