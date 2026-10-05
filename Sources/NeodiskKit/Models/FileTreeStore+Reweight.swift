//
//  FileTreeStore+Reweight.swift
//  Neodisk
//

import Foundation

extension FileTreeStore {
    /// The same tree with every size replaced by another metric (tokens):
    /// files take `weight`, directories the sum of their children, and
    /// siblings re-sort largest first. IDs are unchanged.
    public nonisolated func reweighted(_ weight: (FileNodeRecord) -> Int64) -> FileTreeStore {
        let count = storage.count
        guard count > 0 else { return self }

        var weights = [Int64](repeating: 0, count: count)
        // Descending index order is bottom-up (a parent precedes its children).
        for index in stride(from: count - 1, through: 0, by: -1) {
            let node = storage.nodes[index]
            if !node.isDirectory {
                weights[index] = max(0, weight(node))
            }
            if let parent = storage.parentIndex(of: Int32(index)) {
                weights[Int(parent)] = weights[Int(parent)].addingClamped(weights[index])
            }
        }

        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        var indexByID = NodeIDIndex(minimumCapacity: count)
        nodes.reserveCapacity(count)
        parentIndices.reserveCapacity(count)

        var stack: [(old: Int32, parent: Int32)] = [(0, -1)]
        while let (old, parent) = stack.popLast() {
            let index = Int32(nodes.count)
            let node = storage.nodes[Int(old)]
            nodes.append(node.replacingAllSizes(with: weights[Int(old)]))
            parentIndices.append(parent)
            _ = indexByID.updateValue(index, forKey: node.id)
            // Stable sort keeps the byte order among equal weights.
            let children = storage.childIndices(of: old).enumerated().sorted {
                let (a, b) = (weights[Int($0.element)], weights[Int($1.element)])
                return a != b ? a > b : $0.offset < $1.offset
            }
            for child in children.reversed() {
                stack.append((child.element, index))
            }
        }

        let (childStarts, childSlots) = TreeStorage.childLayout(parentIndices: parentIndices)
        let reweighted = TreeStorage(
            nodes: nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: childSlots,
            indexByID: indexByID,
            nodeHashes: NodeIDIndex.parallelHashes(of: nodes)
        )
        let stats = aggregateStats
        return FileTreeStore(
            trustedStorage: reweighted,
            rootID: rootID,
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: weights[0],
                totalLogicalSize: weights[0],
                fileCount: stats.fileCount,
                directoryCount: stats.directoryCount,
                accessibleItemCount: stats.accessibleItemCount,
                inaccessibleItemCount: stats.inaccessibleItemCount
            )
        )
    }
}

extension FileNodeRecord {
    nonisolated func replacingAllSizes(with size: Int64) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            allocatedSize: size,
            unduplicatedAllocatedSize: size,
            logicalSize: size,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: linkCount,
            isPackage: isPackage,
            isAccessible: isAccessible,
            isSelfAccessible: isSelfAccessible,
            isSynthetic: isSynthetic,
            isAutoSummarized: isAutoSummarized,
            isDataless: false,
            cloudOnlyLogicalSize: 0
        )
    }
}
