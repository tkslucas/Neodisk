//
//  NodeIDIndex.swift
//  Neodisk
//
//  The node ID (absolute path) → node index map behind TreeStorage. A plain
//  [String: Int32] hashes every long path with SipHash on each insert and
//  lookup, which alone cost ~60% of decoding a millions-of-nodes snapshot,
//  and spends about 50 bytes per node. Keys here hash with FNV-1a, the hash
//  picks one of 16 open-addressing shards so bulk builds from a decoded
//  node array fill all shards in parallel, and a slot is 8 bytes: the key
//  strings are the tree's own node IDs.
//

import Dispatch
import Foundation

/// FNV-1a over a string's UTF-8 — the shared cheap hash for node-ID paths
/// (this index's shard keys, ScanSizeBaseline's size map).
nonisolated enum FNV1a {
    static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var string = string
        string.withUTF8 { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        return hash
    }
}

nonisolated struct NodeIDIndex: Sendable {
    // Open addressing with linear probing, in 16 shards (low hash bits) so
    // bulk builds fill them in parallel. A slot is a node index plus the
    // high 32 bits of its key's hash; keys themselves aren't stored twice:
    // once the index belongs to a tree they're read from its node array,
    // and until then (while a tree is being assembled) from a plain array
    // indexed by value. About 8 bytes per slot, versus the ~50 per node of
    // a Dictionary keyed by path.

    private enum Keys: Sendable {
        /// Key of value v is `nodes[v].id` — the index of a tree.
        case nodes([FileNodeRecord])
        /// Key of value v is `strings[v]` — an index still being filled.
        case strings([String])
    }

    private struct Shard: Sendable {
        /// Node index per slot, or -1 when empty.
        var values: [Int32]
        /// High 32 bits of the key's hash, for cheap mismatch rejection.
        var tags: [UInt32]
        var count = 0

        init(capacity: Int) {
            values = [Int32](repeating: -1, count: capacity)
            tags = [UInt32](repeating: 0, count: capacity)
        }

        var mask: Int { values.count - 1 }
    }

    /// Power of two; shard = low bits of the FNV hash.
    private static let shardCount = 16
    private static let shardBits: UInt64 = 4
    private static let minimumShardCapacity = 8

    private var shards: [Shard]
    private var keys: Keys

    init(minimumCapacity: Int = 0) {
        let perShard = Self.slotCount(for: (minimumCapacity + Self.shardCount - 1) / Self.shardCount)
        shards = (0..<Self.shardCount).map { _ in Shard(capacity: perShard) }
        keys = .strings([])
    }

    /// Slots for `count` keys at a load factor of at most 3/4.
    private static func slotCount(for count: Int) -> Int {
        var capacity = minimumShardCapacity
        while capacity * 3 < count * 4 {
            capacity <<= 1
        }
        return capacity
    }

    private static func shardIndex(for hash: UInt64) -> Int {
        Int(hash & UInt64(shardCount - 1))
    }

    private static func home(for hash: UInt64, mask: Int) -> Int {
        Int(truncatingIfNeeded: hash >> shardBits) & mask
    }

    private static func tag(for hash: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: hash >> 32)
    }

    private func key(for value: Int32) -> String? {
        let position = Int(value)
        switch keys {
        case .nodes(let nodes):
            return nodes.indices.contains(position) ? nodes[position].id : nil
        case .strings(let strings):
            return strings.indices.contains(position) ? strings[position] : nil
        }
    }

    /// The slot holding `id`, or the empty slot where it would go.
    private func probe(_ shard: Shard, hash: UInt64, id: String) -> (slot: Int, found: Bool) {
        let tag = Self.tag(for: hash)
        let mask = shard.mask
        var slot = Self.home(for: hash, mask: mask)
        while true {
            let value = shard.values[slot]
            if value < 0 {
                return (slot, false)
            }
            if shard.tags[slot] == tag, key(for: value) == id {
                return (slot, true)
            }
            slot = (slot + 1) & mask
        }
    }

    subscript(id: String) -> Int32? {
        get {
            lookup(hash: FNV1a.hash(id), id: id)
        }
        set {
            guard let newValue else { return }
            updateValue(newValue, forKey: id, hash: FNV1a.hash(id))
        }
    }

    /// Probe with a precomputed FNV-1a hash of `id` instead of rehashing the
    /// (possibly long) path. Equality still compares the string, so a hash
    /// collision costs a memcmp, never a wrong answer — pass the hash the
    /// storage already stored for the node whose ID you are looking up.
    func lookup(hash: UInt64, id: String) -> Int32? {
        let shard = shards[Self.shardIndex(for: hash)]
        let (slot, found) = probe(shard, hash: hash, id: id)
        return found ? shard.values[slot] : nil
    }

    /// Same contract as Dictionary.updateValue: returns the previous value,
    /// or nil when the key was newly inserted.
    @discardableResult
    mutating func updateValue(_ value: Int32, forKey id: String) -> Int32? {
        updateValue(value, forKey: id, hash: FNV1a.hash(id))
    }

    /// Insert variant that takes an already-computed hash of `id`. Used to
    /// force hash collisions in tests (two different IDs under one hash), and
    /// avoids rehashing when a caller holds the hash already. (A shard that
    /// grows rehashes its keys with FNV-1a, so a forced hash only holds until
    /// then.)
    @discardableResult
    mutating func updateValue(_ value: Int32, forKey id: String, hash: UInt64) -> Int32? {
        precondition(value >= 0, "NodeIDIndex values are node indices")
        storeKey(id, for: value)
        let shardIndex = Self.shardIndex(for: hash)
        let (slot, found) = probe(shards[shardIndex], hash: hash, id: id)
        if found {
            let previous = shards[shardIndex].values[slot]
            shards[shardIndex].values[slot] = value
            return previous
        }
        shards[shardIndex].values[slot] = value
        shards[shardIndex].tags[slot] = Self.tag(for: hash)
        shards[shardIndex].count += 1
        if shards[shardIndex].count * 4 > shards[shardIndex].values.count * 3 {
            grow(shardIndex)
        }
        return nil
    }

    /// Inserts `id` → `value` unless `id` is already present, and returns the
    /// value already there if so (leaving it untouched) — the assemblers'
    /// "first occurrence wins" insert.
    mutating func insertIfAbsent(_ value: Int32, forKey id: String) -> Int32? {
        if let existing = self[id] {
            return existing
        }
        updateValue(value, forKey: id)
        return nil
    }

    /// Records the key for `value` while the index still owns its keys.
    private mutating func storeKey(_ id: String, for value: Int32) {
        guard case .strings(var strings) = keys else {
            // An index attached to a tree takes its keys from the nodes;
            // editing one detaches it first.
            detachKeys()
            storeKey(id, for: value)
            return
        }
        keys = .strings([])
        let position = Int(value)
        if position >= strings.count {
            strings.append(contentsOf: repeatElement("", count: position - strings.count + 1))
        }
        strings[position] = id
        keys = .strings(strings)
    }

    private mutating func detachKeys() {
        guard case .nodes(let nodes) = keys else { return }
        keys = .strings(nodes.map(\.id))
    }

    private mutating func grow(_ shardIndex: Int) {
        let old = shards[shardIndex]
        var grown = Shard(capacity: old.values.count * 2)
        for value in old.values where value >= 0 {
            guard let id = key(for: value) else { continue }
            let hash = FNV1a.hash(id)
            var slot = Self.home(for: hash, mask: grown.mask)
            while grown.values[slot] >= 0 {
                slot = (slot + 1) & grown.mask
            }
            grown.values[slot] = value
            grown.tags[slot] = Self.tag(for: hash)
            grown.count += 1
        }
        shards[shardIndex] = grown
    }

    /// This index, reading its keys from `nodes` (the tree it indexes, where
    /// value v is `nodes[v]`) instead of keeping its own copies.
    func attached(to nodes: [FileNodeRecord]) -> NodeIDIndex {
        var index = self
        index.keys = .nodes(nodes)
        return index
    }

    /// FNV-1a hash of each node's ID, in the node array's order, computed in
    /// disjoint parallel chunks. Shared by `building` (which also shards on
    /// it) and by storage that keeps the per-node hash for later lookups.
    static func parallelHashes(of nodes: [FileNodeRecord]) -> [UInt64] {
        let nodeCount = nodes.count
        guard nodeCount > 0 else { return [] }

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
                    hashesOut[i] = FNV1a.hash(nodesIn[i].id)
                }
            }
        }
        return hashes
    }

    /// Bulk build for a decoded preorder node array: hashes and shard fills
    /// both run in parallel. Returns the built index alongside the per-node
    /// FNV hashes (in node order) so storage can keep them for later lookups
    /// instead of rehashing. Returns nil when two nodes share an ID — the
    /// duplicate detection the serial insert loop used to provide.
    static func building(from nodes: [FileNodeRecord]) -> (index: NodeIDIndex, hashes: [UInt64])? {
        let nodeCount = nodes.count
        guard nodeCount > 0 else { return (NodeIDIndex(), []) }

        let hashes = parallelHashes(of: nodes)
        var shardCounts = [Int](repeating: 0, count: shardCount)
        for hash in hashes {
            shardCounts[shardIndex(for: hash)] += 1
        }

        var index = NodeIDIndex()
        index.keys = .nodes(nodes)
        var builtShards = shardCounts.map { Shard(capacity: slotCount(for: $0)) }
        var duplicateFlags = [Bool](repeating: false, count: shardCount)
        builtShards.withUnsafeMutableBufferPointer { shardBuffer in
            duplicateFlags.withUnsafeMutableBufferPointer { flagBuffer in
                nonisolated(unsafe) let shardsOut = shardBuffer
                nonisolated(unsafe) let flagsOut = flagBuffer
                let hashesIn = hashes
                let reader = index
                // Each iteration owns exactly one shard (and one flag slot).
                DispatchQueue.concurrentPerform(iterations: shardCount) { shardIndex in
                    var shard = shardsOut[shardIndex]
                    let shardMask = UInt64(shardCount - 1)
                    for i in 0..<nodeCount where Int(hashesIn[i] & shardMask) == shardIndex {
                        let (slot, found) = reader.probe(shard, hash: hashesIn[i], id: nodes[i].id)
                        if found {
                            flagsOut[shardIndex] = true
                            return
                        }
                        shard.values[slot] = Int32(i)
                        shard.tags[slot] = tag(for: hashesIn[i])
                        shard.count += 1
                    }
                    shardsOut[shardIndex] = shard
                }
            }
        }
        guard !duplicateFlags.contains(true) else { return nil }
        index.shards = builtShards
        return (index, hashes)
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
