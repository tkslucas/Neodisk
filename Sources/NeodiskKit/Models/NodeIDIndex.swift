//
//  NodeIDIndex.swift
//  Neodisk
//
//  The node ID (absolute path) → node index map behind TreeStorage. A plain
//  [String: Int32] hashes every long path with SipHash on each insert and
//  lookup, which alone cost ~60% of decoding a millions-of-nodes snapshot.
//  Keys here carry a precomputed FNV-1a hash of the path — Hashable combines
//  just that one word, and the hash picks one of 16 shards so bulk builds
//  from a decoded node array fill all shards in parallel.
//

import Dispatch
import Foundation

nonisolated struct NodeIDIndex: Sendable {
    /// Node ID plus its FNV-1a hash; equality still compares the string, so
    /// FNV collisions cost a memcmp, never a wrong answer.
    private struct HashedKey: Hashable {
        let hash: UInt64
        let id: String

        static func == (lhs: HashedKey, rhs: HashedKey) -> Bool {
            lhs.hash == rhs.hash && lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(hash)
        }
    }

    /// Power of two; shard = low bits of the FNV hash.
    private static let shardCount = 16

    private var shards: [[HashedKey: Int32]]

    init(minimumCapacity: Int = 0) {
        let perShard = (minimumCapacity + Self.shardCount - 1) / Self.shardCount
        shards = (0..<Self.shardCount).map { _ in
            [HashedKey: Int32](minimumCapacity: perShard)
        }
    }

    private static func fnv1a(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var id = id
        id.withUTF8 { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    private static func shardIndex(for hash: UInt64) -> Int {
        Int(hash & UInt64(shardCount - 1))
    }

    var count: Int {
        shards.reduce(0) { $0 + $1.count }
    }

    subscript(id: String) -> Int32? {
        get {
            let hash = Self.fnv1a(id)
            return shards[Self.shardIndex(for: hash)][HashedKey(hash: hash, id: id)]
        }
        set {
            let hash = Self.fnv1a(id)
            shards[Self.shardIndex(for: hash)][HashedKey(hash: hash, id: id)] = newValue
        }
    }

    /// Same contract as Dictionary.updateValue: returns the previous value,
    /// or nil when the key was newly inserted.
    @discardableResult
    mutating func updateValue(_ value: Int32, forKey id: String) -> Int32? {
        let hash = Self.fnv1a(id)
        return shards[Self.shardIndex(for: hash)]
            .updateValue(value, forKey: HashedKey(hash: hash, id: id))
    }

    /// Bulk build for a decoded preorder node array: hashes and shard fills
    /// both run in parallel. Returns nil when two nodes share an ID — the
    /// duplicate detection the serial insert loop used to provide.
    static func building(from nodes: [FileNodeRecord]) -> NodeIDIndex? {
        let nodeCount = nodes.count
        guard nodeCount > 0 else { return NodeIDIndex() }

        var hashes = [UInt64](repeating: 0, count: nodeCount)
        hashes.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let hashesOut = buffer
            let nodesIn = nodes
            // Disjoint chunks; each element written exactly once.
            let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, 16)
            let chunkSize = (nodeCount + chunkCount - 1) / chunkCount
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let start = min(chunk * chunkSize, nodeCount)
                let end = min(start + chunkSize, nodeCount)
                for i in start..<end {
                    hashesOut[i] = fnv1a(nodesIn[i].id)
                }
            }
        }

        var builtShards = [[HashedKey: Int32]?](repeating: nil, count: shardCount)
        var duplicateFlags = [Bool](repeating: false, count: shardCount)
        builtShards.withUnsafeMutableBufferPointer { shardBuffer in
            duplicateFlags.withUnsafeMutableBufferPointer { flagBuffer in
                nonisolated(unsafe) let shardsOut = shardBuffer
                nonisolated(unsafe) let flagsOut = flagBuffer
                let nodesIn = nodes
                let hashesIn = hashes
                // Each iteration owns exactly one shard (and one flag slot).
                DispatchQueue.concurrentPerform(iterations: shardCount) { shard in
                    var dictionary = [HashedKey: Int32](
                        minimumCapacity: nodeCount / shardCount + nodeCount / (shardCount * 4)
                    )
                    let shardMask = UInt64(shardCount - 1)
                    for i in 0..<nodeCount where Int(hashesIn[i] & shardMask) == shard {
                        let key = HashedKey(hash: hashesIn[i], id: nodesIn[i].id)
                        if dictionary.updateValue(Int32(i), forKey: key) != nil {
                            flagsOut[shard] = true
                            return
                        }
                    }
                    shardsOut[shard] = dictionary
                }
            }
        }
        guard !duplicateFlags.contains(true) else { return nil }

        var index = NodeIDIndex()
        index.shards = builtShards.map { $0 ?? [:] }
        return index
    }
}

extension NodeIDIndex: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, Int32)...) {
        self.init(minimumCapacity: elements.count)
        for (id, index) in elements {
            self[id] = index
        }
    }
}
