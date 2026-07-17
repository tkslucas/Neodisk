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

    /// The ancestor-rebuild step as an injectable function. Production passes
    /// `numericAncestorRebuild`; the equivalence tests pass a closure over
    /// `legacyRebuildAffectedAncestors` to prove the post-assembly dedup entry
    /// points produce field-identical stores either way.
    typealias AncestorRebuild = (
        Set<Int32>, inout [FileNodeRecord], [Int32], [Int32], inout [Int32]
    ) -> Void

    nonisolated static func numericAncestorRebuild(
        _ changed: Set<Int32>, _ nodes: inout [FileNodeRecord],
        _ parentIndices: [Int32], _ childStarts: [Int32], _ childSlots: inout [Int32]
    ) {
        rebuildAffectedAncestors(
            of: changed, nodes: &nodes,
            parentIndices: parentIndices, childStarts: childStarts, childSlots: &childSlots,
            cancellationCheck: {}
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
        minimumAllocatedSizeByNodeID: [String: Int64],
        rebuild: AncestorRebuild = numericAncestorRebuild
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

        rebuild(changedIndices, &nodes, parentIndices, childStarts, &childSlots)
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

        var nodes = storage.nodes
        var childSlots = storage.childSlots
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

        guard !changedIndices.isEmpty else { return store }

        try rebuildAffectedAncestors(
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

    /// Rebuilds every ancestor directory of the changed nodes bottom-up:
    /// totals re-sum their children and the child display order is
    /// re-sorted in place. Descending index order is bottom-up because a
    /// preorder parent always has a smaller index than its descendants.
    /// Shared with CloneDeduplicator, whose passes end the same way.
    ///
    /// Numeric in-place rebuild: totals are summed by reading child fields
    /// directly from `nodes` (no `orderedChildIndices.map { nodes[$0] }`
    /// whole-record copies) and the parent record is rebuilt from `path`
    /// (no per-directory `URL` construction). On hardlink/clone-heavy trees
    /// the affected-ancestor set covers most of the tree, so the fat copies
    /// and URL builds `legacyRebuildAffectedAncestors` did dominated
    /// assembly (~38s of a ~42s home-dir assemble); this reproduces its
    /// output field-for-field — see `DedupRebuildEquivalenceTests`.
    nonisolated static func rebuildAffectedAncestors(
        of changedIndices: Set<Int32>,
        nodes: inout [FileNodeRecord],
        parentIndices: [Int32],
        childStarts: [Int32],
        childSlots: inout [Int32],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        guard !changedIndices.isEmpty else { return }

        try rebuildDirectories(
            affectedAncestorIndices(of: changedIndices, parentIndices: parentIndices),
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            cancellationCheck: cancellationCheck
        )
    }

    /// Re-aggregates and re-sorts an explicit set of directory indices
    /// bottom-up (descending index = deepest first, so a parent re-sums
    /// already-rebuilt children). `rebuildAffectedAncestors` passes the
    /// ancestor closure of changed nodes; the splice-with-removals path passes
    /// the affected parents directly, because a removed child leaves no node in
    /// the new array to seed an ancestor walk from.
    nonisolated static func rebuildDirectories(
        _ directoryIndices: Set<Int32>,
        nodes: inout [FileNodeRecord],
        parentIndices: [Int32],
        childStarts: [Int32],
        childSlots: inout [Int32],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        guard !directoryIndices.isEmpty else { return }

        for directoryIndex in directoryIndices.sorted(by: >) {
            try cancellationCheck()
            let dir = Int(directoryIndex)
            guard nodes[dir].isDirectory else { continue }

            let range = Int(childStarts[dir])..<Int(childStarts[dir + 1])
            // Re-sort the child index list by the display comparator, reading
            // sizes/names in place rather than through childDisplayOrder's
            // by-value FileNodeRecord parameters (which copy each record).
            var orderedChildIndices = Array(childSlots[range])
            orderedChildIndices.sort { lhs, rhs in
                let lhsAllocated = nodes[Int(lhs)].allocatedSize
                let rhsAllocated = nodes[Int(rhs)].allocatedSize
                if lhsAllocated == rhsAllocated {
                    return nodes[Int(lhs)].name.localizedStandardCompare(nodes[Int(rhs)].name) == .orderedAscending
                }
                return lhsAllocated > rhsAllocated
            }
            childSlots.replaceSubrange(range, with: orderedChildIndices)

            // Re-aggregate totals from the child records in place, matching
            // FileNodeRecord.directory's field choices exactly.
            var allocatedSize: Int64 = 0
            var logicalSize: Int64 = 0
            var cloudOnlyLogicalSize: Int64 = 0
            var descendantFileCount = 0
            var childrenAreAccessible = true
            for childIndex in orderedChildIndices {
                let ci = Int(childIndex)
                allocatedSize = allocatedSize.addingClamped(nodes[ci].allocatedSize)
                logicalSize = logicalSize.addingClamped(nodes[ci].logicalSize)
                cloudOnlyLogicalSize = cloudOnlyLogicalSize.addingClamped(nodes[ci].cloudOnlyLogicalSize)
                if nodes[ci].isDirectory {
                    descendantFileCount += nodes[ci].descendantFileCount
                } else if !nodes[ci].isSymbolicLink && !nodes[ci].isSynthetic {
                    descendantFileCount += 1
                }
                childrenAreAccessible = childrenAreAccessible && nodes[ci].isAccessible
            }

            let current = nodes[dir]
            nodes[dir] = FileNodeRecord(
                id: current.id,
                path: current.path,
                name: current.name,
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: allocatedSize,
                logicalSize: logicalSize,
                descendantFileCount: descendantFileCount,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible && childrenAreAccessible,
                isSelfAccessible: current.isSelfAccessible,
                isSynthetic: false,
                isAutoSummarized: false,
                cloudOnlyLogicalSize: cloudOnlyLogicalSize
            )
        }
    }

    /// The ancestor directories of `changedIndices`, walking parent links up
    /// to the root. Shared by the numeric rebuild and its reference oracle.
    nonisolated static func affectedAncestorIndices(
        of changedIndices: Set<Int32>,
        parentIndices: [Int32]
    ) -> Set<Int32> {
        var affectedDirectoryIndices = Set<Int32>()
        for index in changedIndices {
            var cursor = parentIndices[Int(index)]
            while cursor >= 0, affectedDirectoryIndices.insert(cursor).inserted {
                cursor = parentIndices[Int(cursor)]
            }
        }
        return affectedDirectoryIndices
    }

    /// The pre-numeric rebuild, kept verbatim as the byte-identical oracle for
    /// `rebuildAffectedAncestors` (see `DedupRebuildEquivalenceTests`). Not used
    /// in production; retained so the equivalence tests can prove the numeric
    /// rebuild reproduces it exactly.
    nonisolated static func legacyRebuildAffectedAncestors(
        of changedIndices: Set<Int32>,
        nodes: inout [FileNodeRecord],
        parentIndices: [Int32],
        childStarts: [Int32],
        childSlots: inout [Int32],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        guard !changedIndices.isEmpty else { return }

        let affectedDirectoryIndices = affectedAncestorIndices(
            of: changedIndices,
            parentIndices: parentIndices
        )

        for directoryIndex in affectedDirectoryIndices.sorted(by: >) {
            try cancellationCheck()
            let current = nodes[Int(directoryIndex)]
            guard current.isDirectory else { continue }

            let range = Int(childStarts[Int(directoryIndex)])..<Int(childStarts[Int(directoryIndex) + 1])
            var orderedChildIndices = Array(childSlots[range])
            orderedChildIndices.sort { lhs, rhs in
                FileTreeStore.childDisplayOrder(nodes[Int(lhs)], nodes[Int(rhs)])
            }
            childSlots.replaceSubrange(range, with: orderedChildIndices)

            nodes[Int(directoryIndex)] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: orderedChildIndices.map { nodes[Int($0)] },
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
        }
    }

    /// Dictionary-topology variant used by FileTreeStore's subtree mutation
    /// operations, which work on a materialized dictionary view.
    nonisolated static func rebuildAffectedAncestorDirectories(
        for changedNodeIDs: Set<String>,
        nodesByID: inout [String: FileNodeRecord],
        childIDsByID: inout [String: [String]],
        parentIDByID: [String: String],
        cancellationCheck: () throws -> Void = {}
    ) rethrows {
        let affectedDirectoryIDs = affectedAncestorDirectoryIDs(
            for: changedNodeIDs,
            nodesByID: nodesByID,
            parentIDByID: parentIDByID
        )
        for nodeID in affectedDirectoryIDs {
            try cancellationCheck()
            guard let node = nodesByID[nodeID], node.isDirectory else { continue }
            let children = (childIDsByID[nodeID] ?? []).compactMap { nodesByID[$0] }
            let sortedChildren = FileTreeStore.sortedChildren(children)
            nodesByID[nodeID] = FileNodeRecord.directory(
                id: node.id,
                url: node.url,
                name: node.name,
                children: sortedChildren,
                lastModified: node.lastModified,
                fileIdentity: node.fileIdentity,
                linkCount: node.linkCount,
                isPackage: node.isPackage,
                isAccessible: node.isSelfAccessible,
                childrenAreSorted: true
            )
            childIDsByID[nodeID] = sortedChildren.map(\.id)
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
            let sortedClaims = identityClaims.sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.ownerNodeID < rhs.ownerNodeID
                }
                return lhs.path < rhs.path
            }

            for duplicateClaim in sortedClaims.dropFirst() {
                duplicateAllocatedSizeByOwner[duplicateClaim.ownerNodeID, default: 0] += duplicateClaim.allocatedSize
            }
        }

        return duplicateAllocatedSizeByOwner
    }

    private nonisolated static func affectedAncestorDirectoryIDs(
        for changedNodeIDs: Set<String>,
        nodesByID: [String: FileNodeRecord],
        parentIDByID: [String: String]
    ) -> [String] {
        guard !changedNodeIDs.isEmpty else { return [] }

        var affectedDirectoryIDs = Set<String>()
        var visitedAncestorIDs = Set<String>()
        for changedNodeID in changedNodeIDs {
            var cursor = parentIDByID[changedNodeID]
            while let currentID = cursor {
                guard visitedAncestorIDs.insert(currentID).inserted else { break }
                if nodesByID[currentID]?.isDirectory == true {
                    affectedDirectoryIDs.insert(currentID)
                }
                cursor = parentIDByID[currentID]
            }
        }

        var depthByDirectoryID: [String: Int] = [:]
        depthByDirectoryID.reserveCapacity(affectedDirectoryIDs.count)
        for directoryID in affectedDirectoryIDs {
            depthByDirectoryID[directoryID] = treeDepth(of: directoryID, parentIDByID: parentIDByID)
        }

        return affectedDirectoryIDs.sorted { lhs, rhs in
            let lhsDepth = depthByDirectoryID[lhs] ?? 0
            let rhsDepth = depthByDirectoryID[rhs] ?? 0
            if lhsDepth == rhsDepth {
                return lhs < rhs
            }
            return lhsDepth > rhsDepth
        }
    }

    private nonisolated static func treeDepth(
        of nodeID: String,
        parentIDByID: [String: String]
    ) -> Int {
        var depth = 0
        var cursor = nodeID

        while let parentID = parentIDByID[cursor] {
            depth += 1
            cursor = parentID
        }

        return depth
    }
}

nonisolated struct HardLinkClaim: Sendable {
    let identity: FileIdentity
    let ownerNodeID: String
    let path: String
    let allocatedSize: Int64
}

extension FileNodeRecord {
    /// The same record with a refreshed modification date — used by the root
    /// relist to move the scan root's own mtime without disturbing its totals.
    nonisolated func replacingLastModified(_ lastModified: Date?) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo
        )
    }

    nonisolated func replacingAllocatedSize(
        _ allocatedSize: Int64,
        cloneInfo: CloneInfo?? = nil
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedAllocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: isDataless,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            cloneInfo: cloneInfo ?? self.cloneInfo
        )
    }
}
