// Re-sums and re-sorts ancestors after sizes change; shared by the dedup passes, numeric splice
// and dictionary subtree mutations.

import Foundation

nonisolated enum AncestorRebuilder {
    /// Descending index is bottom-up in preorder. Reads in place: the reference rebuild's record copies
    /// and URL builds took ~38s of a ~42s assemble (`DedupRebuildEquivalenceTests`).
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

    /// The splice-with-removals path passes affected parents directly: a removed child leaves no node to seed
    /// an ancestor walk from.
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
            // Reads in place: childDisplayOrder's by-value FileNodeRecord parameters copy each record.
            var orderedChildIndices = Array(childSlots[range])
            #if canImport(Darwin)
            // Names bridged once each, not on every tie comparison.
            let keyed = orderedChildIndices.map { index in
                (index: index, size: nodes[Int(index)].allocatedSize, name: nodes[Int(index)].name as NSString)
            }
            orderedChildIndices = keyed.sorted { lhs, rhs in
                lhs.size == rhs.size
                    ? DisplayNameOrder.precedes(lhs.name, rhs.name)
                    : lhs.size > rhs.size
            }.map(\.index)
            #else
            orderedChildIndices.sort { lhs, rhs in
                let lhsAllocated = nodes[Int(lhs)].allocatedSize
                let rhsAllocated = nodes[Int(rhs)].allocatedSize
                if lhsAllocated == rhsAllocated {
                    return DisplayNameOrder.precedes(nodes[Int(lhs)].name, nodes[Int(rhs)].name)
                }
                return lhsAllocated > rhsAllocated
            }
            #endif
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
                isAccessible: node.isSelfAccessible
            )
            childIDsByID[nodeID] = sortedChildren.map(\.id)
        }
    }

    /// Only sizes ever change, never ids, so the stored per-node hashes carry over unchanged.
    nonisolated static func rebalancedStore(
        _ store: FileTreeStore,
        cancellationCheck: () throws -> Void = {},
        computeCharges: (_ nodes: inout [FileNodeRecord]) throws -> Set<Int32>
    ) throws -> FileTreeStore {
        let storage = store.storage
        var nodes = storage.nodes
        var childSlots = storage.childSlots

        let changedIndices = try computeCharges(&nodes)
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
                nodeHashes: storage.nodeHashes
            ),
            rootID: store.rootID
        )
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
