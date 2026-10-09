//
//  FuzzySearch.swift
//  Neodisk
//
//  fzf-style fuzzy name matching, shared by the outline's entire-scan
//  search and the kind drill-in filter: subsequence matching with ranked
//  scoring — consecutive-run and word-start bonuses, gap penalties.
//

import Foundation
import NeodiskKit

/// One searchable node — the entry shape of the shared per-snapshot search
/// index (see SnapshotSearchIndex) that serves both the outline's
/// entire-scan search and the kind drill-in filter.
///
/// An index holds one entry per node of a scan (millions), so entries are
/// small: a node index into one shared table plus pre-classified kind
/// codes. Names are matched in place with ASCII case folding; only names
/// whose lowercase needs more than that keep a lowercased copy (in the
/// table), so per-keystroke scoring never allocates. Kinds are classified
/// once so the drill-in list can filter the index without re-touching nodes.
package struct FileSearchEntry: Sendable {
    private let table: SearchEntryTable
    private let nodeIndex: Int32
    private let categoryCode: UInt32
    private let typeCode: UInt32
    /// Whether the node participates in kind statistics (files, packages,
    /// auto-summarized folders).
    package let isKindCountable: Bool
    package let allocatedSize: Int64

    init(
        table: SearchEntryTable,
        nodeIndex: Int32,
        categoryCode: UInt32,
        typeCode: UInt32,
        isKindCountable: Bool,
        allocatedSize: Int64
    ) {
        self.table = table
        self.nodeIndex = nodeIndex
        self.categoryCode = categoryCode
        self.typeCode = typeCode
        self.isKindCountable = isKindCountable
        self.allocatedSize = allocatedSize
    }

    /// A standalone entry (its own one-node table), for tests and small
    /// hand-built lists.
    package init(
        id: String,
        lowercasedName: String,
        allocatedSize: Int64,
        categoryKindID: String = "",
        typeKindID: String = "",
        isKindCountable: Bool = false,
        lastModified: Date? = nil
    ) {
        self.init(
            table: SearchEntryTable(
                standaloneID: id,
                lowercasedName: lowercasedName,
                lastModified: lastModified,
                kindIDs: [categoryKindID, typeKindID]
            ),
            nodeIndex: 0,
            categoryCode: 0,
            typeCode: 1,
            isKindCountable: isKindCountable,
            allocatedSize: allocatedSize
        )
    }

    package var id: String { table.id(at: nodeIndex) }
    /// Modification date, so the age drill-in can bucket the index.
    package var lastModified: Date? { table.lastModified(at: nodeIndex) }
    /// The node's kind ID under `.categories` grouping.
    package var categoryKindID: String { table.kindIDs[Int(categoryCode)] }
    /// The node's kind ID under `.types` grouping.
    package var typeKindID: String { table.kindIDs[Int(typeCode)] }

    package func kindID(for mode: FileKindDisplayMode) -> String {
        switch mode {
        case .categories: return categoryKindID
        case .types: return typeKindID
        }
    }

    /// The lowercased name. Allocates; matching uses `withLowercasedName`.
    package var lowercasedName: String {
        withLowercasedName { String(decoding: Array($0), as: UTF8.self) }
    }

    /// Calls `body` with the lowercased name's UTF-8, without allocating
    /// for names that ASCII folding lowercases fully (nearly all of them).
    package func withLowercasedName<R>(_ body: (LowercasedNameBytes) -> R) -> R {
        if let lowercased = table.lowercasedOverride(at: nodeIndex) {
            return body(LowercasedNameBytes(utf8: lowercased.utf8, foldsASCII: false))
        }
        return body(LowercasedNameBytes(utf8: table.name(at: nodeIndex).utf8, foldsASCII: true))
    }
}

/// A name's UTF-8 as lowercased bytes: either already lowercase, or folded
/// from ASCII uppercase as it's read.
package struct LowercasedNameBytes: Sequence {
    let utf8: String.UTF8View
    let foldsASCII: Bool

    package var count: Int { utf8.count }

    package func makeIterator() -> Iterator {
        Iterator(base: utf8.makeIterator(), foldsASCII: foldsASCII)
    }

    package struct Iterator: IteratorProtocol {
        var base: String.UTF8View.Iterator
        let foldsASCII: Bool

        package mutating func next() -> UInt8? {
            guard let byte = base.next() else { return nil }
            return foldsASCII && byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
        }
    }
}

/// What an index's entries share: the scan's node array (IDs, names, and
/// dates are read from it, never copied), the kind-ID strings the entries'
/// codes point at, and lowercased copies of the few names that ASCII case
/// folding doesn't fully lowercase.
package final class SearchEntryTable: Sendable {
    private let nodes: [FileNodeRecord]
    let kindIDs: [String]
    private let lowercasedOverrides: [Int32: String]
    /// Standalone entries (tests) have no node array.
    private let standalone: (id: String, name: String, lastModified: Date?)?

    init(nodes: [FileNodeRecord], kindIDs: [String], lowercasedOverrides: [Int32: String]) {
        self.nodes = nodes
        self.kindIDs = kindIDs
        self.lowercasedOverrides = lowercasedOverrides
        standalone = nil
    }

    init(standaloneID id: String, lowercasedName: String, lastModified: Date?, kindIDs: [String]) {
        nodes = []
        self.kindIDs = kindIDs
        lowercasedOverrides = [:]
        standalone = (id, lowercasedName, lastModified)
    }

    func id(at index: Int32) -> String {
        standalone?.id ?? nodes[Int(index)].id
    }

    func name(at index: Int32) -> String {
        standalone?.name ?? nodes[Int(index)].name
    }

    func lastModified(at index: Int32) -> Date? {
        standalone.map { $0.lastModified } ?? nodes[Int(index)].lastModified
    }

    func lowercasedOverride(at index: Int32) -> String? {
        lowercasedOverrides.isEmpty ? nil : lowercasedOverrides[index]
    }

    /// Whether folding ASCII uppercase gives the same bytes as
    /// `String.lowercased()` for this name.
    static func asciiFoldingLowercases(_ name: String) -> Bool {
        var name = name
        return name.withUTF8 { bytes in !bytes.contains { $0 >= 0x80 } }
            || name.lowercased() == String(decoding: name.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }, as: UTF8.self)
    }
}

package enum FuzzyMatcher {
    private static let matchBonus = 16
    // Consecutive runs must outscore the same letters scattered across
    // word starts, or "log" ranks "large-old-gif.png" beside "log.txt".
    private static let consecutiveBonus = 12
    private static let wordStartBonus = 12
    private static let gapPenalty = 1

    /// Bytes that make the following character a "word start" in file
    /// names: separators, dots, and friends.
    private static func isWordSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "."), UInt8(ascii: "_"),
             UInt8(ascii: "-"), UInt8(ascii: "/"), UInt8(ascii: "("),
             UInt8(ascii: "["), UInt8(ascii: "+"), UInt8(ascii: "@"):
            return true
        default:
            return false
        }
    }

    /// Greedy forward subsequence match of pre-lowercased query bytes
    /// against a pre-lowercased name. Returns nil unless every query byte
    /// appears in order; higher scores are better. (fzf's v2 algorithm
    /// re-optimizes match positions; greedy is a deliberate simplification —
    /// wrong rankings need pathological names, and never drop matches.)
    package static func score(queryBytes: [UInt8], lowercasedName: String) -> Int? {
        score(queryBytes: queryBytes, lowercasedNameBytes: lowercasedName.utf8)
    }

    package static func score(queryBytes: [UInt8], entry: FileSearchEntry) -> Int? {
        entry.withLowercasedName { score(queryBytes: queryBytes, lowercasedNameBytes: $0) }
    }

    private static func score(queryBytes: [UInt8], lowercasedNameBytes: some Sequence<UInt8>) -> Int? {
        guard !queryBytes.isEmpty else { return 0 }

        var score = 0
        var queryIndex = 0
        var previousMatched = false
        // Start-of-name counts as a word start.
        var previousByte: UInt8 = UInt8(ascii: " ")

        for byte in lowercasedNameBytes {
            if queryIndex < queryBytes.count, byte == queryBytes[queryIndex] {
                score += Self.matchBonus
                if previousMatched {
                    score += Self.consecutiveBonus
                }
                if Self.isWordSeparator(previousByte) {
                    score += Self.wordStartBonus
                }
                queryIndex += 1
                previousMatched = true
            } else {
                // Only gaps inside the match window cost anything; a match
                // at the end of a long name shouldn't lose to noise.
                if queryIndex > 0, queryIndex < queryBytes.count {
                    score -= Self.gapPenalty
                }
                previousMatched = false
            }
            previousByte = byte
        }

        return queryIndex == queryBytes.count ? score : nil
    }

    /// How often the whole-index loops poll `Task.isCancelled`: cheap
    /// enough to vanish next to scoring, frequent enough that a superseded
    /// keystroke stops within microseconds instead of finishing the scan.
    package static let cancellationCheckInterval = 4_096

    /// The `limit` best-scoring entries for a query, plus how many matched
    /// in total — the outline search's ranking, where the best name match
    /// belongs on top. Ties break to shorter names, then larger files
    /// (between two identically-named items, the disk analyzer cares about
    /// the fat one), then stable by ID. An empty query returns the first
    /// `limit` entries in their given order. `isIncluded` scopes the match
    /// to a slice of a shared index (outline search skips the root) without
    /// copying entries.
    ///
    /// Only the best `limit` matches are kept, in a bounded heap: a match
    /// that can't beat the worst kept one is rejected in one comparison, so
    /// a broad query over a million names never sorts the whole match list.
    /// Cancellation is polled every `cancellationCheckInterval` entries;
    /// a cancelled call returns early with partial results the caller must
    /// discard (callers re-check `Task.isCancelled` after awaiting).
    package static func topMatches(
        query: String,
        entries: [FileSearchEntry],
        limit: Int,
        where isIncluded: (FileSearchEntry) -> Bool = { _ in true }
    ) -> (ids: [String], totalMatches: Int) {
        let queryBytes = Array(query.lowercased().utf8)
        guard !queryBytes.isEmpty else {
            var ids: [String] = []
            var total = 0
            for (index, entry) in entries.enumerated() {
                if index % cancellationCheckInterval == 0, Task.isCancelled { break }
                guard isIncluded(entry) else { continue }
                total += 1
                if ids.count < limit {
                    ids.append(entry.id)
                }
            }
            return (ids, total)
        }

        var best = TopMatchHeap(capacity: limit)
        var total = 0
        for (index, entry) in entries.enumerated() {
            if index % cancellationCheckInterval == 0, Task.isCancelled { break }
            guard isIncluded(entry) else { continue }
            if let score = Self.score(queryBytes: queryBytes, entry: entry) {
                total += 1
                best.offer(RankedMatch(
                    score: score,
                    nameLength: entry.withLowercasedName(\.count),
                    allocatedSize: entry.allocatedSize,
                    index: index
                ), entries: entries)
            }
        }
        return (best.sortedBestFirst(entries: entries).map { entries[$0.index].id }, total)
    }

    /// A scored match with its tie-break keys hoisted out of the entry, so
    /// heap comparisons touch the entry only for the final ID tie-break.
    package struct RankedMatch {
        package let score: Int
        package let nameLength: Int
        package let allocatedSize: Int64
        package let index: Int

        /// The ranking's strict total order: higher score, then shorter
        /// name, then larger file, then smaller ID.
        package func ranksAbove(_ other: RankedMatch, entries: [FileSearchEntry]) -> Bool {
            if score != other.score { return score > other.score }
            if nameLength != other.nameLength { return nameLength < other.nameLength }
            if allocatedSize != other.allocatedSize { return allocatedSize > other.allocatedSize }
            return entries[index].id < entries[other.index].id
        }
    }

    /// Bounded top-k selection: a binary heap holding the best `capacity`
    /// matches seen so far, with the *worst* kept match at the root so each
    /// new candidate is accepted or rejected against it in O(1), and kept in
    /// O(log k).
    package struct TopMatchHeap {
        package let capacity: Int
        package private(set) var storage: [RankedMatch] = []

        package init(capacity: Int) {
            self.capacity = max(capacity, 0)
            storage.reserveCapacity(min(self.capacity, 1_024))
        }

        package mutating func offer(_ match: RankedMatch, entries: [FileSearchEntry]) {
            guard capacity > 0 else { return }
            if storage.count < capacity {
                storage.append(match)
                siftUp(storage.count - 1, entries: entries)
            } else if match.ranksAbove(storage[0], entries: entries) {
                storage[0] = match
                siftDown(0, entries: entries)
            }
        }

        /// The kept matches, best first.
        package func sortedBestFirst(entries: [FileSearchEntry]) -> [RankedMatch] {
            storage.sorted { $0.ranksAbove($1, entries: entries) }
        }

        /// Heap order: a parent ranks at or below its children (worst on top).
        private mutating func siftUp(_ start: Int, entries: [FileSearchEntry]) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard storage[parent].ranksAbove(storage[child], entries: entries) else { return }
                storage.swapAt(parent, child)
                child = parent
            }
        }

        private mutating func siftDown(_ start: Int, entries: [FileSearchEntry]) {
            var parent = start
            let count = storage.count
            while true {
                let left = 2 * parent + 1
                guard left < count else { return }
                var worst = left
                let right = left + 1
                if right < count, storage[worst].ranksAbove(storage[right], entries: entries) {
                    worst = right
                }
                guard storage[parent].ranksAbove(storage[worst], entries: entries) else { return }
                storage.swapAt(parent, worst)
                parent = worst
            }
        }
    }

    /// The first `limit` entries matching the query, in the entries' given
    /// order, plus how many matched in total — the statistics file lists'
    /// filter. Their browse order is allocated-size descending, and typing
    /// must narrow that ranking, not replace it with match-quality order
    /// (filtering a size list for "mov" should keep the biggest movie
    /// first). An empty query matches everything. Polls cancellation like
    /// `topMatches`; a cancelled call returns partial results.
    package static func matchesInEntryOrder(
        query: String,
        entries: [FileSearchEntry],
        limit: Int
    ) -> (ids: [String], totalMatches: Int) {
        let queryBytes = Array(query.lowercased().utf8)
        var ids: [String] = []
        var total = 0
        for (index, entry) in entries.enumerated() {
            if index % cancellationCheckInterval == 0, Task.isCancelled { break }
            guard Self.score(queryBytes: queryBytes, entry: entry) != nil else {
                continue
            }
            total += 1
            if ids.count < limit {
                ids.append(entry.id)
            }
        }
        return (ids, total)
    }
}
