//
//  FuzzySearch.swift
//  Neodisk
//
//  fzf-style fuzzy name matching, shared by the outline's entire-scan
//  search and the kind drill-in filter: subsequence matching with ranked
//  scoring — consecutive-run and word-start bonuses, gap penalties.
//

import SwiftUI
import NeodiskKit

/// One searchable node — the entry shape of the shared per-snapshot search
/// index (see SnapshotSearchIndex) that serves both the outline's
/// entire-scan search and the kind drill-in filter. Names are
/// pre-lowercased once at index build so per-keystroke scoring never
/// allocates; kind IDs are pre-classified once so the drill-in list can
/// filter the index without re-touching nodes.
struct FileSearchEntry: Sendable {
    let id: String
    let lowercasedName: String
    let allocatedSize: Int64
    /// The node's kind ID under `.categories` grouping.
    let categoryKindID: String
    /// The node's kind ID under `.types` grouping.
    let typeKindID: String
    /// Whether the node participates in kind statistics (files, packages,
    /// auto-summarized folders).
    let isKindCountable: Bool
    /// Modification date, so the age drill-in can bucket the index without
    /// re-touching nodes.
    let lastModified: Date?

    init(
        id: String,
        lowercasedName: String,
        allocatedSize: Int64,
        categoryKindID: String = "",
        typeKindID: String = "",
        isKindCountable: Bool = false,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.lowercasedName = lowercasedName
        self.allocatedSize = allocatedSize
        self.categoryKindID = categoryKindID
        self.typeKindID = typeKindID
        self.isKindCountable = isKindCountable
        self.lastModified = lastModified
    }

    func kindID(for mode: FileKindDisplayMode) -> String {
        switch mode {
        case .categories: return categoryKindID
        case .types: return typeKindID
        }
    }
}

enum FuzzyMatcher {
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
    static func score(queryBytes: [UInt8], lowercasedName: String) -> Int? {
        guard !queryBytes.isEmpty else { return 0 }

        var score = 0
        var queryIndex = 0
        var previousMatched = false
        // Start-of-name counts as a word start.
        var previousByte: UInt8 = UInt8(ascii: " ")

        for byte in lowercasedName.utf8 {
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

    /// The `limit` best-scoring entries for a query, plus how many matched
    /// in total — the outline search's ranking, where the best name match
    /// belongs on top. Ties break to shorter names, then larger files
    /// (between two identically-named items, the disk analyzer cares about
    /// the fat one), then stable by ID. An empty query returns the first
    /// `limit` entries in their given order. `isIncluded` scopes the match
    /// to a slice of a shared index (outline search skips the root) without
    /// copying entries.
    ///
    /// Whole-scan scoring of a million names finishes in a few hundred
    /// milliseconds; callers run it off the main actor behind a debounce
    /// and drop stale results, so there is no cancellation hook.
    static func topMatches(
        query: String,
        entries: [FileSearchEntry],
        limit: Int,
        where isIncluded: (FileSearchEntry) -> Bool = { _ in true }
    ) -> (ids: [String], totalMatches: Int) {
        let queryBytes = Array(query.lowercased().utf8)
        guard !queryBytes.isEmpty else {
            var ids: [String] = []
            var total = 0
            for entry in entries where isIncluded(entry) {
                total += 1
                if ids.count < limit {
                    ids.append(entry.id)
                }
            }
            return (ids, total)
        }

        var matches: [(score: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            guard isIncluded(entry) else { continue }
            if let score = Self.score(queryBytes: queryBytes, lowercasedName: entry.lowercasedName) {
                matches.append((score, index))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let lhsEntry = entries[lhs.index]
            let rhsEntry = entries[rhs.index]
            if lhsEntry.lowercasedName.utf8.count != rhsEntry.lowercasedName.utf8.count {
                return lhsEntry.lowercasedName.utf8.count < rhsEntry.lowercasedName.utf8.count
            }
            if lhsEntry.allocatedSize != rhsEntry.allocatedSize {
                return lhsEntry.allocatedSize > rhsEntry.allocatedSize
            }
            return lhsEntry.id < rhsEntry.id
        }

        return (matches.prefix(limit).map { entries[$0.index].id }, matches.count)
    }

    /// The first `limit` entries matching the query, in the entries' given
    /// order, plus how many matched in total — the statistics file lists'
    /// filter. Their browse order is allocated-size descending, and typing
    /// must narrow that ranking, not replace it with match-quality order
    /// (filtering a size list for "mov" should keep the biggest movie
    /// first). An empty query matches everything.
    static func matchesInEntryOrder(
        query: String,
        entries: [FileSearchEntry],
        limit: Int
    ) -> (ids: [String], totalMatches: Int) {
        let queryBytes = Array(query.lowercased().utf8)
        var ids: [String] = []
        var total = 0
        for entry in entries {
            guard Self.score(queryBytes: queryBytes, lowercasedName: entry.lowercasedName) != nil else {
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
