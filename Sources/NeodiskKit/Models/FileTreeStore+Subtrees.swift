//
//  FileTreeStore+Subtrees.swift
//  Neodisk
//

import Foundation

// Subtree mutation API (remove/replace/scope) extracted from FileTreeStore.swift
// purely to keep each file a manageable size. `StoreError` and the private
// helpers `subtreeNodeIDs`/`emptyRootNode`/`preflightReplacement` are used only
// by the methods below, so they move here and stay `private` (file-scoped to
// this file) without any access-level change.
extension FileTreeStore {
    private enum StoreError: LocalizedError {
        case replacementIDCollision(String)
        case overlappingReplacementTargets(String, String)

        var errorDescription: String? {
            switch self {
            case .replacementIDCollision(let id):
                return "The replacement tree reuses an existing node ID outside the replaced subtree: \(id)."
            case .overlappingReplacementTargets(let ancestorID, let descendantID):
                return "The replacement targets overlap: \(ancestorID) is an ancestor of \(descendantID)."
            }
        }
    }

    public nonisolated func removingSubtrees(rootedAt nodeIDs: [String]) -> FileTreeStore {
        (try? removingSubtrees(rootedAt: nodeIDs, cancellationCheck: {})) ?? self
    }

    public nonisolated func removingSubtrees(
        rootedAt nodeIDs: [String],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore {
        try cancellationCheck()
        let removalIDs = topLevelNodeIDs(from: nodeIDs)
        guard !removalIDs.isEmpty else { return self }
        if removalIDs.contains(rootID) {
            return FileTreeStore(root: emptyRootNode())
        }

        var removedIDs = Set<String>()
        for removalID in removalIDs {
            try cancellationCheck()
            removedIDs.formUnion(try subtreeNodeIDs(
                rootedAt: removalID,
                cancellationCheck: cancellationCheck
            ))
        }
        guard !removedIDs.isEmpty else { return self }

        var (updatedNodes, updatedChildIDs, updatedParentIDs) = storage.dictionaryTopology()
        let originalParentIDs = updatedParentIDs

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        for (offset, entry) in updatedChildIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            guard entry.value.contains(where: { removedIDs.contains($0) }) else { continue }
            updatedChildIDs[entry.key] = entry.value.filter { !removedIDs.contains($0) }
        }

        // Ancestors of the removed subtrees still carry the old totals;
        // rebuild them bottom-up (the pre-removal parent map still knows the
        // removal roots' ancestor chains).
        try HardLinkDeduplicator.rebuildAffectedAncestorDirectories(
            for: Set(removalIDs),
            nodesByID: &updatedNodes,
            childIDsByID: &updatedChildIDs,
            parentIDByID: originalParentIDs,
            cancellationCheck: cancellationCheck
        )

        let updatedStore = FileTreeStore(
            trustedRootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try SharedSizeDeduplication.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    public nonisolated func removingSubtree(id targetID: String) -> FileTreeStore? {
        try? removingSubtree(id: targetID, cancellationCheck: {})
    }

    public nonisolated func removingSubtree(
        id targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = storage.index(of: targetID),
              let parentIndex = storage.parentIndex(of: targetIndex) else {
            return nil
        }
        let parentID = storage.nodes[Int(parentIndex)].id

        let removedIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        var (updatedNodes, updatedChildIDs, updatedParentIDs) = storage.dictionaryTopology()

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        let remainingParentChildIDs = (updatedChildIDs[parentID] ?? []).filter { !removedIDs.contains($0) }
        if remainingParentChildIDs.isEmpty {
            updatedChildIDs.removeValue(forKey: parentID)
        } else {
            updatedChildIDs[parentID] = remainingParentChildIDs
        }

        var cursor: String? = parentID
        while let currentID = cursor {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { break }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            if sortedChildRecords.isEmpty {
                updatedChildIDs.removeValue(forKey: currentID)
            } else {
                updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            }
            cursor = updatedParentIDs[currentID]
        }

        let updatedStore = FileTreeStore(
            trustedRootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try SharedSizeDeduplication.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func emptyRootNode() -> FileNodeRecord {
        let root = root
        return FileNodeRecord(
            id: root.id,
            url: root.url,
            name: root.name,
            isDirectory: root.isDirectory,
            isSymbolicLink: root.isSymbolicLink,
            allocatedSize: 0,
            unduplicatedAllocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            isSelfAccessible: root.isSelfAccessible,
            isSynthetic: root.isSynthetic,
            isAutoSummarized: root.isAutoSummarized
        )
    }

    public nonisolated func replacingSubtree(id targetID: String, with replacement: FileTreeStore) -> FileTreeStore? {
        try? replacingSubtree(id: targetID, with: replacement, cancellationCheck: {})
    }

    public nonisolated func replacingSubtree(
        id targetID: String,
        with replacement: FileTreeStore,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = storage.index(of: targetID) else { return nil }

        let oldParentIndex = storage.parentIndex(of: targetIndex)
        let oldParentID = oldParentIndex.map { storage.nodes[Int($0)].id }
        let oldSubtreeIDs = Set(try subtreeNodeIDs(
            rootedAt: targetID,
            cancellationCheck: cancellationCheck
        ))
        try preflightReplacement(
            replacement,
            removing: oldSubtreeIDs,
            cancellationCheck: cancellationCheck
        )
        var (updatedNodes, updatedChildIDs, updatedParentIDs) = storage.dictionaryTopology()

        for (offset, oldID) in oldSubtreeIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: oldID)
            updatedChildIDs.removeValue(forKey: oldID)
            updatedParentIDs.removeValue(forKey: oldID)
        }

        let (replacementNodes, replacementChildIDs, replacementParentIDs) =
            replacement.storage.dictionaryTopology()
        for (offset, entry) in replacementNodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes[entry.key] = entry.value
        }
        for (offset, entry) in replacementChildIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedChildIDs[entry.key] = entry.value
        }
        for (offset, entry) in replacementParentIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedParentIDs[entry.key] = entry.value
        }

        let updatedRootID: String
        if let oldParentID {
            let previousChildIDs = updatedChildIDs[oldParentID] ?? []
            updatedChildIDs[oldParentID] = previousChildIDs.map { childID in
                childID == targetID ? replacement.rootID : childID
            }
            updatedParentIDs[replacement.rootID] = oldParentID
            updatedRootID = rootID
        } else {
            updatedParentIDs.removeValue(forKey: replacement.rootID)
            updatedRootID = replacement.rootID
        }

        var cursor = oldParentID
        while let currentID = cursor {
            try cancellationCheck()
            guard let current = updatedNodes[currentID] else { break }
            let childRecords = (updatedChildIDs[currentID] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[currentID] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            updatedChildIDs[currentID] = sortedChildRecords.map(\.id)
            cursor = updatedParentIDs[currentID]
        }

        let updatedStore = FileTreeStore(
            trustedRootID: updatedRootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try SharedSizeDeduplication.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func preflightReplacement(
        _ replacement: FileTreeStore,
        removing oldSubtreeIDs: Set<String>,
        cancellationCheck: () throws -> Void
    ) throws {
        for (offset, replacementNode) in replacement.storage.nodes.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            if storage.index(of: replacementNode.id) != nil && !oldSubtreeIDs.contains(replacementNode.id) {
                throw StoreError.replacementIDCollision(replacementNode.id)
            }
        }
    }

    public nonisolated func replacingSubtrees(
        _ replacements: [(id: String, store: FileTreeStore)]
    ) -> FileTreeStore? {
        try? replacingSubtrees(replacements, cancellationCheck: {})
    }

    /// Replaces multiple disjoint subtrees as one all-or-nothing topology
    /// transaction: every target is validated (existence, disjointness, ID
    /// collisions across all replacement stores) before the store is mutated,
    /// then the union of the targets' ancestor chains is rebuilt once, bottom
    /// up, followed by a single scan-wide hard-link rebalance so links
    /// crossing replacement boundaries stay correct.
    ///
    /// Returns nil (never a partial splice) when any target is missing or is
    /// the store root — root replacement is a whole-tree swap, not a splice.
    /// Throws `StoreError.overlappingReplacementTargets` when one target is an
    /// ancestor of (or duplicates) another, and `StoreError.replacementIDCollision`
    /// when a replacement reuses a surviving node's ID or an ID another
    /// replacement already introduced. An empty `replacements` returns `self`.
    public nonisolated func replacingSubtrees(
        _ replacements: [(id: String, store: FileTreeStore)],
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard !replacements.isEmpty else { return self }

        let targetIDs = replacements.map(\.id)
        var targetIndexByID: [String: Int32] = [:]
        targetIndexByID.reserveCapacity(targetIDs.count)
        for targetID in targetIDs {
            guard let targetIndex = storage.index(of: targetID) else { return nil }
            // Root replacement is a whole-tree swap, not a splice.
            if targetID == rootID { return nil }
            targetIndexByID[targetID] = targetIndex
        }

        // Targets must be pairwise disjoint. An exact duplicate is a
        // degenerate overlap (a node is trivially its own duplicate's
        // ancestor), so the ancestor walk below is preceded by a uniqueness
        // guard that also names the offender.
        let targetIDSet = Set(targetIDs)
        if targetIDSet.count != targetIDs.count {
            var seen = Set<String>()
            for targetID in targetIDs where !seen.insert(targetID).inserted {
                throw StoreError.overlappingReplacementTargets(targetID, targetID)
            }
        }
        for targetID in targetIDs {
            try cancellationCheck()
            var cursor = storage.parentIndex(of: targetIndexByID[targetID]!)
            while let ancestorIndex = cursor {
                let ancestorID = storage.nodes[Int(ancestorIndex)].id
                if targetIDSet.contains(ancestorID) {
                    throw StoreError.overlappingReplacementTargets(ancestorID, targetID)
                }
                cursor = storage.parentIndex(of: ancestorIndex)
            }
        }

        var oldParentIDByTargetID: [String: String] = [:]
        oldParentIDByTargetID.reserveCapacity(targetIDs.count)
        var removedIDs = Set<String>()
        for targetID in targetIDs {
            let parentIndex = storage.parentIndex(of: targetIndexByID[targetID]!)!
            oldParentIDByTargetID[targetID] = storage.nodes[Int(parentIndex)].id
            removedIDs.formUnion(try subtreeNodeIDs(
                rootedAt: targetID,
                cancellationCheck: cancellationCheck
            ))
        }

        // ID collision preflight across ALL replacement stores: an ID may only
        // be reused if it lies inside one of the replaced subtrees (union of
        // removedIDs), and no two replacement stores may introduce the same ID.
        var replacementOwnerByNodeID: [String: String] = [:]
        for (targetID, replacement) in zip(targetIDs, replacements.map(\.store)) {
            for (offset, replacementNode) in replacement.storage.nodes.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                let replacementID = replacementNode.id
                if storage.index(of: replacementID) != nil && !removedIDs.contains(replacementID) {
                    throw StoreError.replacementIDCollision(replacementID)
                }
                if replacementOwnerByNodeID.updateValue(targetID, forKey: replacementID) != nil {
                    throw StoreError.replacementIDCollision(replacementID)
                }
            }
        }

        var (updatedNodes, updatedChildIDs, updatedParentIDs) = storage.dictionaryTopology()

        for (offset, removedID) in removedIDs.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            updatedNodes.removeValue(forKey: removedID)
            updatedChildIDs.removeValue(forKey: removedID)
            updatedParentIDs.removeValue(forKey: removedID)
        }

        for replacement in replacements.map(\.store) {
            let (replacementNodes, replacementChildIDs, replacementParentIDs) =
                replacement.storage.dictionaryTopology()
            for (offset, entry) in replacementNodes.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedNodes[entry.key] = entry.value
            }
            for (offset, entry) in replacementChildIDs.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedChildIDs[entry.key] = entry.value
            }
            for (offset, entry) in replacementParentIDs.enumerated() {
                if offset.isMultiple(of: 256) {
                    try cancellationCheck()
                }
                updatedParentIDs[entry.key] = entry.value
            }
        }

        // Re-point each surviving parent's child slot(s) to the new roots. A
        // parent shared by several targets has every target child rewritten in
        // its single original child list.
        let replacementRootIDByTargetID = Dictionary(
            uniqueKeysWithValues: zip(targetIDs, replacements.map(\.store.rootID))
        )
        let affectedParentIDs = Set(oldParentIDByTargetID.values)
        for parentID in affectedParentIDs {
            try cancellationCheck()
            let previousChildIDs = updatedChildIDs[parentID] ?? []
            updatedChildIDs[parentID] = previousChildIDs.map { childID in
                replacementRootIDByTargetID[childID] ?? childID
            }
        }
        for (targetID, replacementRootID) in replacementRootIDByTargetID {
            updatedParentIDs[replacementRootID] = oldParentIDByTargetID[targetID]!
        }

        // Rebuild the union of affected ancestor chains bottom-up, exactly once
        // per ancestor. Original preorder reversed visits every node after all
        // its descendants, so directory totals re-sum already-rebuilt children.
        var affectedAncestorIDs = Set<String>()
        for parentID in affectedParentIDs {
            var cursor: String? = parentID
            while let currentID = cursor {
                try cancellationCheck()
                affectedAncestorIDs.insert(currentID)
                cursor = updatedParentIDs[currentID]
            }
        }
        for node in storage.nodes.reversed() where affectedAncestorIDs.contains(node.id) {
            try cancellationCheck()
            guard let current = updatedNodes[node.id] else { continue }
            let childRecords = (updatedChildIDs[current.id] ?? []).compactMap { updatedNodes[$0] }
            let sortedChildRecords = Self.sortedChildren(childRecords)
            updatedNodes[current.id] = FileNodeRecord.directory(
                id: current.id,
                url: current.url,
                name: current.name,
                children: sortedChildRecords,
                lastModified: current.lastModified,
                fileIdentity: current.fileIdentity,
                linkCount: current.linkCount,
                isPackage: current.isPackage,
                isAccessible: current.isSelfAccessible,
                childrenAreSorted: true
            )
            updatedChildIDs[current.id] = sortedChildRecords.map(\.id)
        }

        let updatedStore = FileTreeStore(
            trustedRootID: rootID,
            nodesByID: updatedNodes,
            childIDsByID: updatedChildIDs,
            parentIDByID: updatedParentIDs
        )
        return try SharedSizeDeduplication.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
    }

    public nonisolated func subtree(rootedAt targetID: String) -> FileTreeStore? {
        try? subtree(rootedAt: targetID, cancellationCheck: {})
    }

    public nonisolated func subtree(
        rootedAt targetID: String,
        cancellationCheck: () throws -> Void
    ) throws -> FileTreeStore? {
        try cancellationCheck()
        guard let targetIndex = storage.index(of: targetID) else { return nil }

        var scopedNodes: [FileNodeRecord] = []
        var scopedParents: [Int32] = []
        var scopedIndexByID = NodeIDIndex()
        var stack: [(index: Int32, parent: Int32)] = [(targetIndex, -1)]

        while let (index, parent) = stack.popLast() {
            try cancellationCheck()
            let scopedIndex = Int32(scopedNodes.count)
            let node = storage.nodes[Int(index)]
            scopedNodes.append(node)
            scopedParents.append(parent)
            scopedIndexByID[node.id] = scopedIndex
            for childIndex in storage.childIndices(of: index).reversed() {
                stack.append((childIndex, scopedIndex))
            }
        }

        let (childStarts, childSlots) = TreeStorage.childLayout(parentIndices: scopedParents)
        let scopedStore = FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: scopedNodes,
                parentIndices: scopedParents,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: scopedIndexByID,
                nodeHashes: NodeIDIndex.parallelHashes(of: scopedNodes)
            ),
            rootID: targetID
        )
        return try SharedSizeDeduplication.rebalancedStore(scopedStore, cancellationCheck: cancellationCheck)
    }

    private nonisolated func subtreeNodeIDs(
        rootedAt id: String,
        cancellationCheck: () throws -> Void
    ) throws -> [String] {
        guard let targetIndex = storage.index(of: id) else { return [] }
        var result: [String] = []
        var stack = [targetIndex]

        while let currentIndex = stack.popLast() {
            try cancellationCheck()
            result.append(storage.nodes[Int(currentIndex)].id)
            stack.append(contentsOf: storage.childIndices(of: currentIndex))
        }

        return result
    }
}
