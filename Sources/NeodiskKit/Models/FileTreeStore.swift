import Foundation

public struct FileTreeStore: Sendable {
    public let rootID: String
    // Contiguous Int32-indexed storage; node identity in the public API stays the String ID (absolute path).
    let storage: TreeStorage
    private let precomputedAggregateStats: ScanAggregateStats?

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

    /// Callers guarantee a consistent tree (engine assembly, snapshot codec, the store's own ops), so
    /// validation is skipped. A violated guarantee degrades to dropped nodes or wrong totals, never a crash.
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

    nonisolated init(
        trustedStorage storage: TreeStorage,
        rootID: String,
        aggregateStats: ScanAggregateStats? = nil
    ) {
        self.rootID = rootID
        self.storage = storage
        self.precomputedAggregateStats = aggregateStats
    }

    /// Drops unreachable nodes and bad references and repairs totals. Roughly doubles construction on
    /// million-node trees, so internal producers use `init(trustedRootID:…)`.
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
}
