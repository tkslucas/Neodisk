// Preorder Int32-indexed storage behind FileTreeStore. Child slots, not `nodes`, own display order: an
// in-place rebuild re-sorts slots without moving records, so serializers must walk the slots.

import Foundation

/// Immutable storage; a class so FileTreeStore value copies are O(1).
nonisolated final class TreeStorage: Sendable {
    /// Sibling order here may lag the display order in `childSlots`.
    let nodes: [FileNodeRecord]
    /// -1 for the root. Parents always precede children, so descending index order is bottom-up.
    let parentIndices: [Int32]
    /// Children of node i occupy `childSlots[childStarts[i]..<childStarts[i+1]]`,
    /// in display (child-list) order. Count is `nodes.count + 1`.
    let childStarts: [Int32]
    let childSlots: [Int32]
    /// Node ID (absolute path) → index. Keys alias the node records' `id`
    /// strings.
    let indexByID: NodeIDIndex
    /// FNV-1a of each ID, so cross-tree lookups can probe another store without rehashing a path. Empty
    /// means not populated (see `nodeHash`).
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
        // The index reads its keys from these nodes instead of holding
        // its own copies (value v is always nodes[v]).
        self.indexByID = indexByID.attached(to: nodes)
        self.nodeHashes = nodeHashes
    }

    var count: Int {
        nodes.count
    }

    func index(of id: String) -> Int32? {
        indexByID[id]
    }

    /// Probes with a caller-supplied hash; string equality still decides matches, so collisions are safe.
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

    /// Display preorder is the canonical sequence for serializing or fingerprinting, since a rebuild may
    /// have re-sorted slots without moving records.
    func forEachIndexInDisplayPreorder(_ body: (Int32) throws -> Void) rethrows {
        guard !nodes.isEmpty else { return }
        var stack: [Int32] = [0]
        stack.reserveCapacity(256)
        while let index = stack.popLast() {
            try body(index)
            let range = Int(childStarts[Int(index)])..<Int(childStarts[Int(index) + 1])
            var slot = range.upperBound
            while slot > range.lowerBound {
                slot -= 1
                stack.append(childSlots[slot])
            }
        }
    }

    /// Repairs child ranges left in stale pre-dedup order by old snapshot files. Detection compares sizes
    /// only so every decode can afford it; equal-size misorders are left as is.
    @discardableResult
    static func restoreChildDisplayOrder(
        nodes: [FileNodeRecord],
        childStarts: [Int32],
        childSlots: inout [Int32]
    ) -> Int {
        // Same comparator as FileTreeStore.childDisplayOrder, reading fields
        // in place so the check never copies whole records.
        func precedes(_ lhs: Int32, _ rhs: Int32) -> Bool {
            let lhsAllocated = nodes[Int(lhs)].allocatedSize
            let rhsAllocated = nodes[Int(rhs)].allocatedSize
            if lhsAllocated == rhsAllocated {
                return DisplayNameOrder.precedes(nodes[Int(lhs)].name, nodes[Int(rhs)].name)
            }
            return lhsAllocated > rhsAllocated
        }

        var repairedCount = 0
        for directory in 0..<max(childStarts.count - 1, 0) {
            let lower = Int(childStarts[directory])
            let upper = Int(childStarts[directory + 1])
            guard upper - lower > 1 else { continue }
            var isOrdered = true
            var previousAllocated = nodes[Int(childSlots[lower])].allocatedSize
            for slot in (lower + 1)..<upper {
                let allocated = nodes[Int(childSlots[slot])].allocatedSize
                if allocated > previousAllocated {
                    isOrdered = false
                    break
                }
                previousAllocated = allocated
            }
            guard !isOrdered else { continue }
            childSlots[lower..<upper].sort(by: precedes)
            repairedCount += 1
        }
        return repairedCount
    }

    /// Missing references are skipped, a duplicate ID keeps its first occurrence, unreachable nodes are dropped.
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
            if indexByID.insertIfAbsent(index, forKey: record.id) != nil {
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

    /// Assigning slots in increasing index order reproduces child-list order, since preorder keeps siblings
    /// ordered.
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

    /// Only for rare subtree mutations that reuse the dictionary algorithms, once per user action.
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
