//
//  HardLinkDeduplicator.swift
//  Neodisk
//

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
        let duplicateAllocatedSizeByOwner = duplicateHardLinkAllocatedSizeByOwner(from: hardLinkClaims)
        guard !duplicateAllocatedSizeByOwner.isEmpty else { return }

        var changedIndices: Set<Int32> = []
        for (nodeID, duplicateAllocatedSize) in duplicateAllocatedSizeByOwner {
            guard let index = indexByID[nodeID] else { continue }
            let node = nodes[Int(index)]
            let minimumAllocatedSize = minimumAllocatedSizeByNodeID[nodeID] ?? 0
            let allocatedSize = max(minimumAllocatedSize, node.allocatedSize - duplicateAllocatedSize)
            guard allocatedSize != node.allocatedSize else { continue }
            nodes[Int(index)] = node.replacingAllocatedSize(allocatedSize)
            changedIndices.insert(index)
        }

        AncestorRebuilder.rebuildAffectedAncestors(
            of: changedIndices,
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            cancellationCheck: {}
        )
    }

    /// Re-derives hard-link claims from the store's own nodes and reapplies
    /// deduplication — used after subtree mutations, where a removed or
    /// replaced owner can shift which link claims a shared file's size.
    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        cancellationCheck: () throws -> Void = {}
    ) throws -> FileTreeStore {
        let storage = store.storage
        var claims: [HardLinkClaim] = []

        for (offset, node) in storage.nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
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

    nonisolated static func duplicateHardLinkAllocatedSizeByOwner(
        from claims: [HardLinkClaim]
    ) -> [String: Int64] {
        let claimsByIdentity = Dictionary(grouping: claims.filter { $0.allocatedSize > 0 }, by: \.identity)
        var duplicateAllocatedSizeByOwner: [String: Int64] = [:]

        for identityClaims in claimsByIdentity.values where identityClaims.count > 1 {
            let sortedClaims = identityClaims.sorted { SharedSizeDeduplication.precedes($0, $1) }

            for duplicateClaim in sortedClaims.dropFirst() {
                duplicateAllocatedSizeByOwner[duplicateClaim.ownerNodeID, default: 0] += duplicateClaim.allocatedSize
            }
        }

        return duplicateAllocatedSizeByOwner
    }
}

nonisolated struct HardLinkClaim: Sendable {
    let identity: FileIdentity
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
}
