//
//  FileTreeStore.swift
//  Neodisk
//

import Foundation

public struct FileTreeStore: Sendable {
    public let rootID: String
    // Contiguous Int32-indexed storage (see TreeStorage). Consumers go
    // through the accessor methods (node(id:), children(of:), allNodes, …);
    // node identity stays the String ID (absolute path) everywhere in the
    // public API.
    let storage: TreeStorage
    private let precomputedAggregateStats: ScanAggregateStats?

    private struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let parentIDByID: [String: String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    private enum StoreError: LocalizedError {
        case replacementIDCollision(String)

        var errorDescription: String? {
            switch self {
            case .replacementIDCollision(let id):
                return "The replacement tree reuses an existing node ID outside the replaced subtree: \(id)."
            }
        }
    }

    public nonisolated var root: FileNodeRecord {
        guard let root = storage.nodes.first, root.id == rootID else {
            preconditionFailure("FileTreeStore rootID does not exist in the store.")
        }
        return root
    }

    public nonisolated var nodeCount: Int {
        storage.count
    }

    /// Every node in the store, in depth-first preorder. `FileNodeRecord.id`
    /// is the node's key, so no separate ID sequence is needed.
    public nonisolated var allNodes: [FileNodeRecord] {
        storage.nodes
    }

    public nonisolated var aggregateStats: ScanAggregateStats {
        if let precomputedAggregateStats {
            return precomputedAggregateStats
        }

        return computedAggregateStats()
    }

    private nonisolated func computedAggregateStats() -> ScanAggregateStats {
        var fileCount = 0
        var directoryCount = 0
        var accessibleItemCount = 0
        var inaccessibleItemCount = 0

        for (index, node) in storage.nodes.enumerated() {
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && storage.childCount(of: Int32(index)) == 0 {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        return ScanAggregateStats(
            totalAllocatedSize: root.allocatedSize,
            totalLogicalSize: root.logicalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            accessibleItemCount: accessibleItemCount,
            inaccessibleItemCount: inaccessibleItemCount
        )
    }

    public nonisolated init(root: FileNodeRecord) {
        self.init(
            trustedRootID: root.id,
            nodesByID: [root.id: root],
            childIDsByID: [:],
            parentIDByID: [:]
        )
    }

    public nonisolated init(root: FileNodeRecord, childrenByID inputChildrenByID: [String: [FileNodeRecord]]) {
        var nodesByID = [root.id: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var seenNodeIDs: Set<String> = [root.id]
        var stack = [root]

        while let parent = stack.popLast() {
            guard let inputChildren = inputChildrenByID[parent.id] else { continue }
            let (uniqueChildren, droppedChildIDs) = Self.uniqueChildrenAndDroppedIDs(
                inputChildren,
                seenNodeIDs: &seenNodeIDs
            )
            let children = Self.sortedChildren(uniqueChildren)
            childIDsByID[parent.id] = children.map(\.id) + droppedChildIDs
            guard !children.isEmpty else { continue }

            for child in children {
                nodesByID[child.id] = child
                parentIDByID[child.id] = parent.id
                stack.append(child)
            }
        }

        self.init(
            rootID: root.id,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID
        )
    }

    /// Trusted fast path — the default for topology produced inside the
    /// package. Callers guarantee a consistent tree: every child reference
    /// resolves, the parent map matches the child map, no node appears under
    /// two parents, and directory totals already sum their children. That
    /// holds for engine assembly (deduped during phase 1/2), the snapshot
    /// codec (validates while reading), and the store's own mutation ops
    /// (which rebuild affected ancestors). The sanitization and repair
    /// passes of the validating init are pure overhead on those paths.
    ///
    /// Storage construction still walks from the root and skips missing or
    /// duplicate references, so a violated guarantee degrades to dropped
    /// nodes or wrong totals, never a crash.
    nonisolated init(
        trustedRootID rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        self.rootID = rootID
        self.storage = TreeStorage.build(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        self.precomputedAggregateStats = aggregateStats
    }

    /// Trusted adoption of prebuilt contiguous storage — the engine's
    /// finalize phase and the snapshot codec construct storage directly
    /// without ever materializing dictionaries.
    nonisolated init(
        trustedStorage storage: TreeStorage,
        rootID: String,
        aggregateStats: ScanAggregateStats? = nil
    ) {
        self.rootID = rootID
        self.storage = storage
        self.precomputedAggregateStats = aggregateStats
    }

    /// Validating init for untrusted topology (arbitrary caller-assembled
    /// dictionaries): drops unreachable nodes, duplicate and dangling child
    /// references, and repairs directory totals where references were
    /// dropped. Known-valid internal producers use `init(trustedRootID:…)`
    /// instead — this pass roughly doubles construction cost on
    /// million-node trees.
    public nonisolated init(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID: [String: String],
        aggregateStats: ScanAggregateStats? = nil
    ) {
        let topology = Self.sanitizedTopology(
            rootID: rootID,
            nodesByID: nodesByID,
            childIDsByID: childIDsByID
        )
        let repairedNodesByID = topology.didDropReferences || aggregateStats == nil
            ? Self.repairMaterializedDirectoryTotals(
                rootID: rootID,
                nodesByID: topology.nodesByID,
                childIDsByID: topology.childIDsByID,
                materializedDirectoryIDs: topology.materializedDirectoryIDs
            )
            : topology.nodesByID
        self.rootID = rootID
        self.storage = TreeStorage.build(
            rootID: rootID,
            nodesByID: repairedNodesByID,
            childIDsByID: topology.childIDsByID
        )
        self.precomputedAggregateStats = topology.didDropReferences ? nil : aggregateStats
    }

    public nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        guard children.count > 1 else { return children }

        return children.sorted(by: childDisplayOrder)
    }

    /// The child display order: largest first, ties by localized name.
    nonisolated static func childDisplayOrder(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> Bool {
        if lhs.allocatedSize == rhs.allocatedSize {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.allocatedSize > rhs.allocatedSize
    }

    private nonisolated static func uniqueChildrenAndDroppedIDs(
        _ children: [FileNodeRecord],
        seenNodeIDs: inout Set<String>
    ) -> (uniqueChildren: [FileNodeRecord], droppedChildIDs: [String]) {
        var uniqueChildren: [FileNodeRecord] = []
        var droppedChildIDs: [String] = []
        uniqueChildren.reserveCapacity(children.count)

        for child in children {
            if seenNodeIDs.insert(child.id).inserted {
                uniqueChildren.append(child)
            } else {
                droppedChildIDs.append(child.id)
            }
        }

        return (uniqueChildren, droppedChildIDs)
    }

    public nonisolated func node(id: String?) -> FileNodeRecord? {
        guard let id, let index = storage.index(of: id) else { return nil }
        return storage.nodes[Int(index)]
    }

    public nonisolated func parent(of id: String?) -> FileNodeRecord? {
        guard let id,
              let index = storage.index(of: id),
              let parentIndex = storage.parentIndex(of: index) else { return nil }
        return storage.nodes[Int(parentIndex)]
    }

    public nonisolated func children(of id: String?) -> [FileNodeRecord] {
        (try? children(of: id, cancellationCheck: {})) ?? []
    }

    public nonisolated func childrenPrefix(of id: String?, maxCount: Int) -> [FileNodeRecord] {
        (try? childrenPrefix(of: id, maxCount: maxCount, cancellationCheck: {})) ?? []
    }

    public nonisolated func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        guard let index = storage.index(of: id ?? rootID) else { return [] }
        let childIndices = storage.childIndices(of: index)

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIndices.count)
        for childIndex in childIndices {
            try cancellationCheck()
            children.append(storage.nodes[Int(childIndex)])
        }
        return children
    }

    public nonisolated func childrenPrefix(
        of id: String?,
        maxCount: Int,
        cancellationCheck: () throws -> Void
    ) throws -> [FileNodeRecord] {
        guard maxCount > 0 else { return [] }
        guard let index = storage.index(of: id ?? rootID) else { return [] }
        let childIndices = storage.childIndices(of: index).prefix(maxCount)

        var children: [FileNodeRecord] = []
        children.reserveCapacity(childIndices.count)
        for childIndex in childIndices {
            try cancellationCheck()
            children.append(storage.nodes[Int(childIndex)])
        }
        return children
    }

    public nonisolated func containsChildren(id: String?) -> Bool {
        guard let index = storage.index(of: id ?? rootID) else { return false }
        return storage.childCount(of: index) > 0
    }

    public nonisolated func indexedNodeIDs(excludingRoot: Bool = false) -> [String] {
        let ids = storage.nodes.map(\.id)
        return excludingRoot && !ids.isEmpty ? Array(ids.dropFirst()) : ids
    }

    public nonisolated func forEachIndexedNodeID(
        excludingRoot: Bool = false,
        _ body: (String) throws -> Void
    ) rethrows {
        for (index, node) in storage.nodes.enumerated() {
            if excludingRoot && index == 0 {
                continue
            }
            try body(node.id)
        }
    }

    public nonisolated func path(to id: String?) -> [FileNodeRecord] {
        guard let id, let index = storage.index(of: id) else {
            return [root]
        }

        var result: [FileNodeRecord] = [storage.nodes[Int(index)]]
        var cursor = index
        while let parentIndex = storage.parentIndex(of: cursor) {
            result.append(storage.nodes[Int(parentIndex)])
            cursor = parentIndex
        }
        return result.reversed()
    }

    public nonisolated func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let descendantID else { return false }
        if ancestorID == descendantID {
            return true
        }
        guard let ancestorIndex = storage.index(of: ancestorID),
              let descendantIndex = storage.index(of: descendantID) else {
            return false
        }

        // In preorder an ancestor always has the smaller index.
        var cursor = descendantIndex
        while let parentIndex = storage.parentIndex(of: cursor), parentIndex >= ancestorIndex {
            if parentIndex == ancestorIndex {
                return true
            }
            cursor = parentIndex
        }
        return false
    }

    public nonisolated func hasAncestor(in ancestorIDs: Set<String>, of nodeID: String) -> Bool {
        guard let index = storage.index(of: nodeID) else {
            return false
        }
        var cursor = index
        while let parentIndex = storage.parentIndex(of: cursor) {
            if ancestorIDs.contains(storage.nodes[Int(parentIndex)].id) {
                return true
            }
            cursor = parentIndex
        }
        return false
    }

    public nonisolated func isNodeOrDescendant(_ nodeID: String, of ancestorIDs: Set<String>) -> Bool {
        ancestorIDs.contains(nodeID) || hasAncestor(in: ancestorIDs, of: nodeID)
    }

    public nonisolated func topLevelNodeIDs(from nodeIDs: [String]) -> [String] {
        let candidateIDs = Set(nodeIDs.filter { storage.index(of: $0) != nil })
        var emittedIDs = Set<String>()
        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        for nodeID in nodeIDs where candidateIDs.contains(nodeID) && !emittedIDs.contains(nodeID) {
            guard !hasAncestor(in: candidateIDs, of: nodeID) else {
                continue
            }
            emittedIDs.insert(nodeID)
            result.append(nodeID)
        }

        return result
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
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
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
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
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
        return try HardLinkDeduplicator.rebalancedStore(updatedStore, cancellationCheck: cancellationCheck)
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
                indexByID: scopedIndexByID
            ),
            rootID: targetID
        )
        return try HardLinkDeduplicator.rebalancedStore(scopedStore, cancellationCheck: cancellationCheck)
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

    private nonisolated static func sanitizedTopology(
        rootID: String,
        nodesByID inputNodesByID: [String: FileNodeRecord],
        childIDsByID inputChildIDsByID: [String: [String]]
    ) -> SanitizedTopology {
        guard let root = inputNodesByID[rootID] else {
            // A rootID absent from nodesByID would otherwise surface as a
            // preconditionFailure on the first `root` access, far from the
            // broken construction site. Degrade to a valid empty tree with a
            // synthesized placeholder root instead.
            let placeholderRoot = FileNodeRecord(
                id: rootID,
                url: URL(filePath: rootID, directoryHint: .isDirectory),
                name: URL(filePath: rootID).lastPathComponent,
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: 0,
                logicalSize: 0,
                descendantFileCount: 0,
                lastModified: nil,
                isPackage: false,
                isAccessible: false,
                isSelfAccessible: false,
                isSynthetic: true,
                isAutoSummarized: false
            )
            return SanitizedTopology(
                nodesByID: [rootID: placeholderRoot],
                childIDsByID: [:],
                parentIDByID: [:],
                materializedDirectoryIDs: [],
                didDropReferences: true
            )
        }

        var nodesByID = [rootID: root]
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID: [String: String] = [:]
        var materializedDirectoryIDs = Set<String>()
        var visited: Set<String> = [rootID]
        var stack = [rootID]

        while let parentID = stack.popLast() {
            guard let childIDs = inputChildIDsByID[parentID] else { continue }
            if inputNodesByID[parentID]?.isDirectory == true {
                materializedDirectoryIDs.insert(parentID)
            }
            guard !childIDs.isEmpty else { continue }

            var sanitizedChildIDs: [String] = []
            sanitizedChildIDs.reserveCapacity(childIDs.count)
            for childID in childIDs {
                guard let child = inputNodesByID[childID] else { continue }
                guard visited.insert(childID).inserted else { continue }
                nodesByID[childID] = child
                parentIDByID[childID] = parentID
                sanitizedChildIDs.append(childID)
            }

            if !sanitizedChildIDs.isEmpty {
                childIDsByID[parentID] = sanitizedChildIDs
                stack.append(contentsOf: sanitizedChildIDs.reversed())
            }
        }

        let materializedInputChildIDsByID = inputChildIDsByID.filter { !$0.value.isEmpty }
        let didDropReferences =
            nodesByID.count != inputNodesByID.count ||
            childIDsByID != materializedInputChildIDsByID

        return SanitizedTopology(
            nodesByID: nodesByID,
            childIDsByID: childIDsByID,
            parentIDByID: parentIDByID,
            materializedDirectoryIDs: materializedDirectoryIDs,
            didDropReferences: didDropReferences
        )
    }

    private nonisolated static func repairMaterializedDirectoryTotals(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        materializedDirectoryIDs: Set<String>
    ) -> [String: FileNodeRecord] {
        guard !materializedDirectoryIDs.isEmpty else { return nodesByID }

        // Repair deepest-first (reverse preorder) so parents see repaired
        // children. The child map is already sanitized: acyclic, unique.
        var preorder: [String] = []
        preorder.reserveCapacity(nodesByID.count)
        var stack = nodesByID[rootID] != nil ? [rootID] : []
        while let nodeID = stack.popLast() {
            preorder.append(nodeID)
            stack.append(contentsOf: (childIDsByID[nodeID] ?? []).reversed())
        }

        var repairedNodes = nodesByID
        for nodeID in preorder.reversed() where materializedDirectoryIDs.contains(nodeID) {
            guard let node = repairedNodes[nodeID], node.isDirectory else { continue }
            let childIDs = childIDsByID[nodeID] ?? []
            let children = childIDs.compactMap { repairedNodes[$0] }
            repairedNodes[nodeID] = repairingDirectoryRecord(node, children: children)
        }
        return repairedNodes
    }

    private nonisolated static func repairingDirectoryRecord(
        _ node: FileNodeRecord,
        children: [FileNodeRecord]
    ) -> FileNodeRecord {
        let allocatedSize = children.reduce(into: Int64(0)) { result, child in
            result = result.addingClamped(child.allocatedSize)
        }
        let logicalSize = children.reduce(into: Int64(0)) { result, child in
            result = result.addingClamped(child.logicalSize)
        }
        let descendantFileCount = children.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }

        return FileNodeRecord(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: node.lastModified,
            fileIdentity: node.fileIdentity,
            linkCount: node.linkCount,
            isPackage: node.isPackage,
            isAccessible: node.isSelfAccessible && children.allSatisfy(\.isAccessible),
            isSelfAccessible: node.isSelfAccessible,
            isSynthetic: node.isSynthetic,
            isAutoSummarized: node.isAutoSummarized
        )
    }
}
