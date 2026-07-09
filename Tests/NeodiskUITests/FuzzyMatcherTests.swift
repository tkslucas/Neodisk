import Foundation
import Testing
@testable import NeodiskUI

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
}
