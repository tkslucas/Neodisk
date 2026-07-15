//
//  TreeStorage.swift
//  Neodisk
//
//  Contiguous Int32-indexed storage behind FileTreeStore. Nodes live in one
//  array in depth-first preorder (the root is index 0, a parent always
//  precedes its descendants, and siblings keep their child-list order);
//  topology is parent indices plus per-node child ranges into a shared
//  child-slot array. The only string-keyed structure left is the id → index
//  map that serves the public String-ID API — its keys share storage with
//  each node's `id`, so paths are stored once.
//

import Foundation

/// Immutable storage; a class so FileTreeStore value copies are O(1).
nonisolated final class TreeStorage: Sendable {
    /// All nodes in depth-first preorder; `nodes[0]` is the root.
    let nodes: [FileNodeRecord]
    /// Parent of `nodes[i]`, or -1 for the root. A parent index is always
    /// smaller than its child's (preorder), so descending index order is
    /// bottom-up.
    let parentIndices: [Int32]
    /// Children of node i occupy `childSlots[childStarts[i]..<childStarts[i+1]]`,
    /// in display (child-list) order. Count is `nodes.count + 1`.
    let childStarts: [Int32]
    let childSlots: [Int32]
    /// Node ID (absolute path) → index. Keys alias the node records' `id`
    /// strings.
    let indexByID: NodeIDIndex
    /// FNV-1a hash of each node's ID, parallel to `nodes`. Lets cross-tree
    /// lookups (the changes-list diff) probe another store's index with an
    /// already-computed hash instead of rehashing a full path. Empty means
    /// "not populated" — callers fall back to rehashing (see `nodeHash`).
    let nodeHashes: [UInt64]

    static let empty = TreeStorage(
        nodes: [],
        parentIndices: [],
        childStarts: [0],
        childSlots: [],
        indexByID: NodeIDIndex()
    )

    init(
        nodes: [FileNodeRecord],
        parentIndices: [Int32],
        childStarts: [Int32],
        childSlots: [Int32],
        indexByID: NodeIDIndex,
        nodeHashes: [UInt64] = []
    ) {
        self.nodes = nodes
        self.parentIndices = parentIndices
        self.childStarts = childStarts
        self.childSlots = childSlots
        self.indexByID = indexByID
        self.nodeHashes = nodeHashes
    }

    var count: Int {
        nodes.count
    }

    func index(of id: String) -> Int32? {
        indexByID[id]
    }

    /// Like `index(of:)` but probes with a caller-supplied FNV-1a hash of
    /// `id` (typically another store's stored `nodeHash`), skipping the
    /// rehash. String equality still decides matches, so collisions are safe.
    func index(of id: String, hash: UInt64) -> Int32? {
        indexByID.lookup(hash: hash, id: id)
    }

    /// FNV-1a hash of `nodes[index].id`. Uses the stored parallel array when
    /// present, otherwise rehashes so every construction path stays correct.
    func nodeHash(at index: Int) -> UInt64 {
        nodeHashes.count == nodes.count ? nodeHashes[index] : FNV1a.hash(nodes[index].id)
    }

    func childIndices(of index: Int32) -> ArraySlice<Int32> {
        childSlots[Int(childStarts[Int(index)])..<Int(childStarts[Int(index) + 1])]
    }

    func childCount(of index: Int32) -> Int {
        Int(childStarts[Int(index) + 1] - childStarts[Int(index)])
    }

    func parentIndex(of index: Int32) -> Int32? {
        let parent = parentIndices[Int(index)]
        return parent < 0 ? nil : parent
    }

    /// Builds storage from dictionary-shaped adjacency by walking from the
    /// root. References to missing nodes are skipped; a duplicate node ID
    /// keeps its first occurrence and drops the repeat (with its subtree).
    /// Nodes unreachable from the root are dropped.
    static func build(
        rootID: String,
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]]
    ) -> TreeStorage {
        guard let root = nodesByID[rootID] else { return .empty }

        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        var indexByID = NodeIDIndex(minimumCapacity: nodesByID.count)
        nodes.reserveCapacity(nodesByID.count)
        parentIndices.reserveCapacity(nodesByID.count)

        var stack: [(record: FileNodeRecord, parent: Int32)] = [(root, -1)]
        while let (record, parent) = stack.popLast() {
            let index = Int32(nodes.count)
            if let existing = indexByID.updateValue(index, forKey: record.id) {
                indexByID[record.id] = existing
                continue
            }
            nodes.append(record)
            parentIndices.append(parent)

            if let childIDs = childIDsByID[record.id], !childIDs.isEmpty {
                for childID in childIDs.reversed() {
                    if let child = nodesByID[childID] {
                        stack.append((child, index))
                    }
                }
            }
        }

        let (childStarts, childSlots) = childLayout(parentIndices: parentIndices)
        return TreeStorage(
            nodes: nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: childSlots,
            indexByID: indexByID,
            nodeHashes: NodeIDIndex.parallelHashes(of: nodes)
        )
    }

    /// Derives the contiguous child ranges from parent links. Assigning
    /// slots in increasing node-index order reproduces child-list order,
    /// because preorder keeps siblings in that order.
    static func childLayout(parentIndices: [Int32]) -> (childStarts: [Int32], childSlots: [Int32]) {
        let count = parentIndices.count
        var childStarts = [Int32](repeating: 0, count: count + 1)
        for parent in parentIndices where parent >= 0 {
            childStarts[Int(parent) + 1] += 1
        }
        for i in 1..<childStarts.count {
            childStarts[i] += childStarts[i - 1]
        }

        var cursors = childStarts
        var childSlots = [Int32](repeating: 0, count: Int(childStarts[count]))
        for index in 0..<count {
            let parent = parentIndices[index]
            guard parent >= 0 else { continue }
            childSlots[Int(cursors[Int(parent)])] = Int32(index)
            cursors[Int(parent)] += 1
        }

        return (childStarts, childSlots)
    }

    /// Materializes the dictionary topology view. Only the rare
    /// subtree-mutation operations use this — they run once per user action
    /// and reuse the dictionary algorithms, then rebuild trusted storage.
    func dictionaryTopology() -> (
        nodesByID: [String: FileNodeRecord],
        childIDsByID: [String: [String]],
        parentIDByID: [String: String]
    ) {
        var nodesByID = [String: FileNodeRecord](minimumCapacity: nodes.count)
        var childIDsByID: [String: [String]] = [:]
        var parentIDByID = [String: String](minimumCapacity: nodes.count)

        for (i, node) in nodes.enumerated() {
            nodesByID[node.id] = node
            let range = Int(childStarts[i])..<Int(childStarts[i + 1])
            if !range.isEmpty {
                childIDsByID[node.id] = childSlots[range].map { nodes[Int($0)].id }
            }
            if let parent = parentIndex(of: Int32(i)) {
                parentIDByID[node.id] = nodes[Int(parent)].id
            }
        }

        return (nodesByID, childIDsByID, parentIDByID)
    }
}
