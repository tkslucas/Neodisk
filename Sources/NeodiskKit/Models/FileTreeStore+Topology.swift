//
//  FileTreeStore+Topology.swift
//  Neodisk
//

import Foundation

// Topology construction/sanitization helpers extracted from FileTreeStore.swift
// purely to keep each file a manageable size.
//
// `SanitizedTopology`, `uniqueChildrenAndDroppedIDs`, `sanitizedTopology`, and
// `repairMaterializedDirectoryTotals` were `private` when nested in the class
// body. They are called from FileTreeStore's own initializers (which stay in
// the core file), so splitting them out promotes them from `private` to
// internal (Swift `private` is file-scoped). They remain out of NeodiskKit's
// public API. `repairingDirectoryRecord` stays `private`: its only caller,
// `repairMaterializedDirectoryTotals`, lives in this same file.
extension FileTreeStore {
    struct SanitizedTopology {
        let nodesByID: [String: FileNodeRecord]
        let childIDsByID: [String: [String]]
        let parentIDByID: [String: String]
        let materializedDirectoryIDs: Set<String>
        let didDropReferences: Bool
    }

    public nonisolated static func sortedChildren(_ children: [FileNodeRecord]) -> [FileNodeRecord] {
        guard children.count > 1 else { return children }

        return children.sorted(by: childDisplayOrder)
    }

    /// The child display order: largest first, ties by localized name.
    nonisolated static func childDisplayOrder(_ lhs: FileNodeRecord, _ rhs: FileNodeRecord) -> Bool {
        if lhs.allocatedSize == rhs.allocatedSize {
            return DisplayNameOrder.precedes(lhs.name, rhs.name)
        }
        return lhs.allocatedSize > rhs.allocatedSize
    }

    nonisolated static func uniqueChildrenAndDroppedIDs(
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

    nonisolated static func sanitizedTopology(
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

    nonisolated static func repairMaterializedDirectoryTotals(
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
        let cloudOnlyLogicalSize = children.reduce(into: Int64(0)) { result, child in
            result = result.addingClamped(child.cloudOnlyLogicalSize)
        }
        let descendantFileCount = children.reduce(into: 0) { result, child in
            if child.isDirectory {
                result += child.descendantFileCount
            } else if !child.isSymbolicLink && !child.isSynthetic {
                result += 1
            }
        }

        // path, not url: the URL round-trip absolutizes non-filesystem paths
        // (cloud targets' cloudscan:// scheme) against the working directory.
        return FileNodeRecord(
            id: node.id,
            path: node.path,
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
            isAutoSummarized: node.isAutoSummarized,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize
        )
    }
}
