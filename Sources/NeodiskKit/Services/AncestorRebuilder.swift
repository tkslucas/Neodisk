//
//  AncestorRebuilder.swift
//  Neodisk
//
//  Generic tree re-aggregation toolkit: after some leaf/node sizes change, the
//  affected ancestor directories must re-sum their children and re-sort their
//  display order. Extracted from HardLinkDeduplicator (it was never hard-link
//  specific): the shared-size dedup passes, the numeric splice, and the
//  dictionary subtree mutations all rebuild ancestors the same way.
//

import Foundation

nonisolated enum AncestorRebuilder {
    /// Rebuilds every ancestor directory of the changed nodes bottom-up:
    /// totals re-sum their children and the child display order is
    /// re-sorted in place. Descending index order is bottom-up because a
    /// preorder parent always has a smaller index than its descendants.
    ///
    /// Numeric in-place rebuild: totals are summed by reading child fields
    /// directly from `nodes` (no `orderedChildIndices.map { nodes[$0] }`
    /// whole-record copies) and the parent record is rebuilt from `path`
    /// (no per-directory `URL` construction). On hardlink/clone-heavy trees
    /// the affected-ancestor set covers most of the tree, so the fat copies
    /// and URL builds the reference rebuild does dominated assembly (~38s of
    /// a ~42s home-dir assemble); this reproduces its output field-for-field
    /// — see `DedupRebuildEquivalenceTests`.
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

    /// Shared skeleton for the two shared-size rebalance passes
    /// (`HardLinkDeduplicator` / `CloneDeduplicator`): `computeCharges` lowers
    /// or restores allocated sizes in place and returns the indices it changed;
    /// the skeleton then rebuilds affected ancestors and reconstructs the
    /// store. Only node sizes ever change, never ids, so the stored per-node
    /// hashes carry over unchanged.
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
