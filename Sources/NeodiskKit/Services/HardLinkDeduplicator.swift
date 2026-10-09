//
//  HardLinkDeduplicator.swift
//  Neodisk
//

import Dispatch
import Foundation

nonisolated struct HardLinkDeduplicator {
    nonisolated static func claim(
        for metadata: NodeMetadata,
        ownerNodeID: String,
        path: String
    ) -> HardLinkClaim? {
        guard !metadata.isDirectory,
              !metadata.isSymbolicLink,
              metadata.linkCount > 1,
              let fileIdentity = metadata.fileIdentity else {
            return nil
        }

        return HardLinkClaim(
            identity: fileIdentity,
            ownerNodeID: ownerNodeID,
            path: path,
            allocatedSize: metadata.allocatedSize
        )
    }

    /// Applies hard-link deduplication to prebuilt mutable tree arrays (the
    /// engine's finalize handoff): each duplicate claim's size is subtracted
    /// from its owner, affected ancestor directories are rebuilt bottom-up,
    /// and child orders are re-sorted where sizes changed.
    nonisolated static func applyDeduplication(
        nodes: inout [FileNodeRecord],
        parentIndices: [Int32],
        childStarts: [Int32],
        childSlots: inout [Int32],
        indexByID: NodeIDIndex,
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSizeByNodeID: [String: Int64]
    ) {
        let duplicates = duplicateClaimIndices(from: hardLinkClaims)
        guard !duplicates.isEmpty else { return }

        // Resolve each duplicate's owner to its node index — read-only
        // index lookups, so they fan out — then total the charges in a flat
        // per-node array rather than a dictionary keyed by path.
        let owners = ownerIndices(of: duplicates, in: hardLinkClaims, indexByID: indexByID)
        var chargeByIndex = [Int64](repeating: 0, count: nodes.count)
        for (position, claimIndex) in duplicates.enumerated() where owners[position] >= 0 {
            chargeByIndex[Int(owners[position])] += hardLinkClaims[Int(claimIndex)].allocatedSize
        }
        var minimumAllocatedSizeByIndex: [Int32: Int64] = [:]
        for (nodeID, minimum) in minimumAllocatedSizeByNodeID {
            if let index = indexByID[nodeID] {
                minimumAllocatedSizeByIndex[index] = minimum
            }
        }

        let changedIndices = applyCharges(
            chargeByIndex,
            minimumAllocatedSizeByIndex: minimumAllocatedSizeByIndex,
            to: &nodes
        )

        AncestorRebuilder.rebuildAffectedAncestors(
            of: changedIndices,
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            cancellationCheck: {}
        )
    }

    private static var concurrency: Int {
        min(ProcessInfo.processInfo.activeProcessorCount, 16)
    }

    /// The node index of each duplicate claim's owner, -1 when the owner is
    /// not in the tree. Disjoint chunks; each element written exactly once.
    private nonisolated static func ownerIndices(
        of duplicates: [Int32],
        in claims: [HardLinkClaim],
        indexByID: NodeIDIndex
    ) -> [Int32] {
        var owners = [Int32](repeating: -1, count: duplicates.count)
        let count = duplicates.count
        owners.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let ownersOut = buffer
            let chunkCount = concurrency
            let chunkSize = (count + chunkCount - 1) / chunkCount
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let start = min(chunk * chunkSize, count)
                let end = min(start + chunkSize, count)
                for position in start..<end {
                    ownersOut[position] = indexByID[claims[Int(duplicates[position])].ownerNodeID] ?? -1
                }
            }
        }
        return owners
    }

    /// Lowers each charged node's allocated size (never below its floor) in
    /// place, in parallel over disjoint node ranges; returns the indices it
    /// changed.
    private nonisolated static func applyCharges(
        _ chargeByIndex: [Int64],
        minimumAllocatedSizeByIndex: [Int32: Int64],
        to nodes: inout [FileNodeRecord]
    ) -> Set<Int32> {
        let count = nodes.count
        let chunkCount = concurrency
        let chunkSize = (count + chunkCount - 1) / chunkCount
        var changedByChunk = [[Int32]](repeating: [], count: chunkCount)
        nodes.withUnsafeMutableBufferPointer { nodeBuffer in
            changedByChunk.withUnsafeMutableBufferPointer { changedBuffer in
                nonisolated(unsafe) let nodesInOut = nodeBuffer
                nonisolated(unsafe) let changedOut = changedBuffer
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let start = min(chunk * chunkSize, count)
                    let end = min(start + chunkSize, count)
                    var changed: [Int32] = []
                    for index in start..<end where chargeByIndex[index] != 0 {
                        let current = nodesInOut[index].allocatedSize
                        let minimum = minimumAllocatedSizeByIndex[Int32(index)] ?? 0
                        let allocatedSize = max(minimum, current - chargeByIndex[index])
                        guard allocatedSize != current else { continue }
                        nodesInOut[index] = nodesInOut[index].replacingAllocatedSize(allocatedSize)
                        changed.append(Int32(index))
                    }
                    changedOut[chunk] = changed
                }
            }
        }
        var changedIndices: Set<Int32> = []
        changedIndices.reserveCapacity(changedByChunk.reduce(0) { $0 + $1.count })
        for changed in changedByChunk {
            changedIndices.formUnion(changed)
        }
        return changedIndices
    }

    /// Re-derives hard-link claims from the store's own nodes and reapplies
    /// deduplication — used after subtree mutations, where a removed or
    /// replaced owner can shift which link claims a shared file's size.
    /// `identities`, when given, limits the pass to those files (the ones an
    /// edit touched; see `SharedSizeDeduplication.Scope`).
    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        identities: Set<FileIdentity>? = nil,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        let storage = store.storage
        if let identities, identities.isEmpty { return store }
        var claims: [HardLinkClaim] = []

        for (offset, node) in storage.nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if let identities {
                guard node.linkCount > 1, let identity = node.fileIdentity,
                      identities.contains(identity) else { continue }
            }
            guard let claim = claim(for: node) else { continue }
            claims.append(claim)
        }

        guard !claims.isEmpty else { return store }

        let duplicateAllocatedSizeByOwner = duplicateHardLinkAllocatedSizeByOwner(from: claims)
        var targetAllocatedSizeByNodeID: [String: Int64] = [:]
        targetAllocatedSizeByNodeID.reserveCapacity(claims.count)
        for claim in claims {
            targetAllocatedSizeByNodeID[claim.ownerNodeID] = claim.allocatedSize
        }
        for (nodeID, duplicateAllocatedSize) in duplicateAllocatedSizeByOwner {
            let baseAllocatedSize = targetAllocatedSizeByNodeID[nodeID] ?? 0
            targetAllocatedSizeByNodeID[nodeID] = max(0, baseAllocatedSize - duplicateAllocatedSize)
        }

        return try AncestorRebuilder.rebalancedStore(store, cancellationCheck: cancellationCheck) { nodes in
            var changedIndices: Set<Int32> = []
            for (offset, entry) in targetAllocatedSizeByNodeID.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                guard let index = storage.index(of: entry.key) else { continue }
                let node = nodes[Int(index)]
                guard node.allocatedSize != entry.value else { continue }
                nodes[Int(index)] = node.replacingAllocatedSize(entry.value)
                changedIndices.insert(index)
            }
            return changedIndices
        }
    }

    private nonisolated static func claim(for node: FileNodeRecord) -> HardLinkClaim? {
        guard !node.isDirectory,
              !node.isSymbolicLink,
              !node.isSynthetic,
              node.linkCount > 1,
              let fileIdentity = node.fileIdentity else {
            return nil
        }

        return HardLinkClaim(
            identity: fileIdentity,
            ownerNodeID: node.id,
            path: node.path,
            allocatedSize: node.unduplicatedAllocatedSize
        )
    }

    /// Each file's claims beyond the first (in `SharedSizeDeduplication`
    /// order) charge their owner the file's size.
    nonisolated static func duplicateHardLinkAllocatedSizeByOwner(
        from claims: [HardLinkClaim]
    ) -> [String: Int64] {
        var duplicateAllocatedSizeByOwner: [String: Int64] = [:]
        for index in duplicateClaimIndices(from: claims) {
            let claim = claims[Int(index)]
            duplicateAllocatedSizeByOwner[claim.ownerNodeID, default: 0] += claim.allocatedSize
        }
        return duplicateAllocatedSizeByOwner
    }

    /// The claims charged as duplicates: every claim of a file except the
    /// first in `SharedSizeDeduplication` order. Claims of one file are
    /// chained through claim indices rather than copied into an array per
    /// file: package-manager stores (pnpm, bun) hard-link one file into
    /// dozens of projects, and on a developer home with millions of such
    /// links the per-file arrays and claim copies dominated finalize.
    nonisolated static func duplicateClaimIndices(from claims: [HardLinkClaim]) -> [Int32] {
        var headByIdentity: [FileIdentity: Int32] = [:]
        headByIdentity.reserveCapacity(claims.count)
        var next = [Int32](repeating: -1, count: claims.count)
        for index in claims.indices where claims[index].allocatedSize > 0 {
            if let head = headByIdentity.updateValue(Int32(index), forKey: claims[index].identity) {
                next[index] = head
            }
        }

        // Only the keeper (the first claim in order) is special, so each
        // file needs a minimum search, not a sort.
        var duplicates: [Int32] = []
        duplicates.reserveCapacity(claims.count - headByIdentity.count)
        for head in headByIdentity.values where next[Int(head)] >= 0 {
            var keeper = head
            var cursor = next[Int(head)]
            while cursor >= 0 {
                if SharedSizeDeduplication.precedes(claims[Int(cursor)], claims[Int(keeper)]) {
                    keeper = cursor
                }
                cursor = next[Int(cursor)]
            }
            cursor = head
            while cursor >= 0 {
                if cursor != keeper {
                    duplicates.append(cursor)
                }
                cursor = next[Int(cursor)]
            }
        }
        return duplicates
    }
}

nonisolated struct HardLinkClaim: Sendable {
    let identity: FileIdentity
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
}
