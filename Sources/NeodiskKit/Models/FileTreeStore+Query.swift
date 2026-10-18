import Foundation

// Split out of FileTreeStore.swift for size; it reads only `storage` and `root`, so no access changes.
extension FileTreeStore {
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
}
