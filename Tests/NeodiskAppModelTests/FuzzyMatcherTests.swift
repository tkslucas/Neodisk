import Foundation
import Testing
@testable import NeodiskAppModel

@Suite struct FuzzyMatcherTests {
    private func score(_ query: String, _ name: String) -> Int? {
        FuzzyMatcher.score(
            queryBytes: Array(query.lowercased().utf8),
            lowercasedName: name.lowercased()
        )
    }

    @Test func testSubsequenceMatchingBasics() {
        #expect(score("mov", "movie.mp4") != nil)
        #expect(score("mp4", "movie.mp4") != nil)
        #expect(score("mvp", "movie.mp4") != nil) // m-o-V-ie.m-P-4? m,v,p in order
        #expect(score("xyz", "movie.mp4") == nil)
        #expect(score("moviex", "movie.mp4") == nil)
        #expect(score("", "movie.mp4") == 0)
    }

    @Test func testCaseInsensitive() {
        #expect(score("CLIP", "Clip.mov") != nil)
    }

    @Test func testConsecutiveRunOutranksScattered() throws {
        let consecutive = try #require(score("log", "log.txt"))
        let scattered = try #require(score("log", "large-old-gif.png"))
        #expect(consecutive > scattered)
    }

    @Test func testWordStartOutranksMidWord() throws {
        let wordStart = try #require(score("re", "release-notes.txt"))
        let midWord = try #require(score("re", "gore.txt"))
        #expect(wordStart > midWord)
    }

    @Test func testNonASCIINamesAreSafe() {
        #expect(score("café", "café-menu.pdf") != nil)
        #expect(score("menu", "café-menu.pdf") != nil)
    }

    @Test func testTopMatchesRanksAndBreaksTies() {
        let entries = [
            FileSearchEntry(id: "/a/notes-backup.txt", lowercasedName: "notes-backup.txt", allocatedSize: 10),
            FileSearchEntry(id: "/a/notes.txt", lowercasedName: "notes.txt", allocatedSize: 10),
            FileSearchEntry(id: "/b/notes.txt", lowercasedName: "notes.txt", allocatedSize: 99),
            FileSearchEntry(id: "/a/unrelated.png", lowercasedName: "unrelated.png", allocatedSize: 5),
        ]

        let (ids, total) = FuzzyMatcher.topMatches(query: "notes", entries: entries, limit: 2)

        #expect(total == 3)
        // Same score for the two exact "notes.txt": bigger file first.
        #expect(ids == ["/b/notes.txt", "/a/notes.txt"])
    }

    @Test func testMatchesInEntryOrderKeepsGivenOrderAndCounts() {
        // Size-descending, like the statistics file lists' entries.
        let entries = [
            FileSearchEntry(id: "/huge-movie.mov", lowercasedName: "huge-movie.mov", allocatedSize: 900),
            FileSearchEntry(id: "/notes.txt", lowercasedName: "notes.txt", allocatedSize: 500),
            FileSearchEntry(id: "/movie.mov", lowercasedName: "movie.mov", allocatedSize: 100),
            FileSearchEntry(id: "/mov-tiny.mov", lowercasedName: "mov-tiny.mov", allocatedSize: 1),
        ]

        let (ids, total) = FuzzyMatcher.matchesInEntryOrder(query: "mov", entries: entries, limit: 2)

        // "movie.mov" out-scores "huge-movie.mov" on match quality, but the
        // size order must survive filtering; the limit trims the tail only.
        #expect(total == 3)
        #expect(ids == ["/huge-movie.mov", "/movie.mov"])

        let (allIDs, allTotal) = FuzzyMatcher.matchesInEntryOrder(query: "", entries: entries, limit: 10)
        #expect(allTotal == 4)
        #expect(allIDs.first == "/huge-movie.mov")
    }

    @Test func testEmptyQueryPreservesEntryOrder() {
        let entries = [
            FileSearchEntry(id: "/big", lowercasedName: "big", allocatedSize: 100),
            FileSearchEntry(id: "/small", lowercasedName: "small", allocatedSize: 1),
        ]
        let (ids, total) = FuzzyMatcher.topMatches(query: "", entries: entries, limit: 10)
        #expect(total == 2)
        #expect(ids == ["/big", "/small"])
    }

    /// The bounded heap must reproduce the full sort exactly — same IDs,
    /// same order, same total — including across heavy ties on score, name
    /// length, and size, and for limits of 0, 1, below, at, and above the
    /// match count.
    @Test func testTopMatchesHeapEqualsFullSort() {
        var rng = SeededTestGenerator(seed: 0x5EA2C4)
        // A tiny alphabet and few sizes force every tie-break level.
        let syllables = ["a", "b", "ab", "ba", "note", "not", "s", ".", "-", " "]
        let sizes: [Int64] = [0, 1, 7, 7, 100]
        let queries = ["a", "ab", "n", "note", "b.a", "s-", "zz", "a b"]
        for round in 0..<60 {
            let count = Int.random(in: 0...400, using: &rng)
            let entries = (0..<count).map { index in
                let name = (0..<Int.random(in: 1...5, using: &rng))
                    .map { _ in syllables.randomElement(using: &rng)! }
                    .joined()
                // Occasional duplicate IDs: identical keys everywhere.
                let id = Int.random(in: 0..<20, using: &rng) == 0
                    ? "/dup/\(name)" : "/\(round)/\(index)/\(name)"
                return FileSearchEntry(
                    id: id, lowercasedName: name,
                    allocatedSize: sizes.randomElement(using: &rng)!
                )
            }
            let excluded = entries.randomElement(using: &rng)?.id
            for query in queries {
                for limit in [0, 1, 3, 17, 100, count, count + 5] {
                    let expected = referenceTopMatches(
                        query: query, entries: entries, limit: limit
                    ) { $0.id != excluded }
                    let actual = FuzzyMatcher.topMatches(
                        query: query, entries: entries, limit: limit
                    ) { $0.id != excluded }
                    #expect(actual.ids == expected.ids, "round \(round) query \(query) limit \(limit)")
                    #expect(actual.totalMatches == expected.totalMatches)
                }
            }
        }
    }

    /// A cancelled search stops within one poll interval instead of
    /// scoring the rest of the index: the scan cancels its own task at a
    /// known entry and must not visit more than one interval past it.
    @Test func testTopMatchesStopsSoonAfterCancellation() async {
        let interval = FuzzyMatcher.cancellationCheckInterval
        let entries = (0..<(interval * 10)).map {
            FileSearchEntry(id: "/f\($0)", lowercasedName: "file\($0).txt", allocatedSize: 1)
        }
        let cancelAt = interval * 2 + 17
        let visited = await Task.detached { () -> Int in
            var visited = 0
            _ = FuzzyMatcher.topMatches(query: "file", entries: entries, limit: 10) { _ in
                if visited == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
                visited += 1
                return true
            }
            return visited
        }.value
        #expect(visited > cancelAt)
        #expect(visited <= interval * 3)
    }

    /// Already-cancelled callers get no work done at all, in both matchers.
    @Test func testCancelledMatchersReturnImmediately() async {
        let entries = (0..<10_000).map {
            FileSearchEntry(id: "/f\($0)", lowercasedName: "file\($0).txt", allocatedSize: 1)
        }
        let (top, ordered, empty) = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return (
                FuzzyMatcher.topMatches(query: "file", entries: entries, limit: 10),
                FuzzyMatcher.matchesInEntryOrder(query: "file", entries: entries, limit: 10),
                FuzzyMatcher.topMatches(query: "", entries: entries, limit: 10)
            )
        }.value
        #expect(top.totalMatches == 0 && top.ids.isEmpty)
        #expect(ordered.totalMatches == 0 && ordered.ids.isEmpty)
        #expect(empty.totalMatches == 0 && empty.ids.isEmpty)
    }
}

/// The pre-heap ranking: collect every match, full-sort, take the
/// prefix. The reference the bounded top-k selection must reproduce, and
/// the "before" side of the search bench.
func referenceTopMatches(
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
        if let score = FuzzyMatcher.score(queryBytes: queryBytes, lowercasedName: entry.lowercasedName) {
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

    return (matches.prefix(max(limit, 0)).map { entries[$0.index].id }, matches.count)
}
