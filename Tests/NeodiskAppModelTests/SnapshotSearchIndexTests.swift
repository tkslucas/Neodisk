//
//  SnapshotSearchIndexTests.swift
//  NeodiskAppModelTests
//
//  The compact search index reads IDs, names, and dates from the scan's
//  node array instead of copying them: entries must still answer exactly
//  what the node holds, sort by size, classify kinds, and match names case-
//  insensitively — ASCII by folding in place, anything else through the
//  lowercased copies the index keeps for those names only.
//

import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

@Suite struct SnapshotSearchIndexTests {
    private func index() -> SnapshotSearchIndex {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let children = [
            makeTestFileNode(id: "/r/Holiday.MOV", name: "Holiday.MOV", size: 900, lastModified: date),
            makeTestFileNode(id: "/r/ÉTÉ.txt", name: "ÉTÉ.txt", size: 50),
            makeTestFileNode(id: "/r/notes.txt", name: "notes.txt", size: 10),
        ]
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        return SnapshotSearchIndex.build(store: store, snapshotID: UUID())
    }

    @Test func entriesReadTheirNodesAndSortBySize() {
        let entries = index().entries
        #expect(entries.map(\.id) == ["/r", "/r/Holiday.MOV", "/r/ÉTÉ.txt", "/r/notes.txt"])
        #expect(entries[1].lastModified == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(entries[1].isKindCountable)
        #expect(entries[1].categoryKindID == FileKindClassifier.kindID(
            for: makeTestFileNode(id: "/x.MOV", name: "x.MOV"), mode: .categories
        ))
        #expect(entries[1].typeKindID != entries[3].typeKindID)
    }

    @Test func namesMatchCaseInsensitively() {
        let entries = index().entries
        #expect(entries[1].lowercasedName == "holiday.mov")
        #expect(entries[2].lowercasedName == "été.txt")
        #expect(FuzzyMatcher.topMatches(query: "HOLI", entries: entries, limit: 5).ids == ["/r/Holiday.MOV"])
        #expect(FuzzyMatcher.topMatches(query: "été", entries: entries, limit: 5).ids == ["/r/ÉTÉ.txt"])
        #expect(FuzzyMatcher.matchesInEntryOrder(query: "txt", entries: entries, limit: 5).ids
            == ["/r/ÉTÉ.txt", "/r/notes.txt"])
    }
}
