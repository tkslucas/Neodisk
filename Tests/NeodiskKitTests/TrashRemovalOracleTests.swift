import Foundation
import Testing
@testable import NeodiskKit

/// The tree after a move to the Trash must be the tree a rescan would find: each case moves real items out of
/// the scanned folder (a rename, as the Trash does), rescans, and compares every node with the spliced tree.
@Suite struct TrashRemovalOracleTests {
    private static let cases: [[String]] = [
        ["a/big.bin"],
        ["a"],
        ["b/hard.bin"],
        ["a/deep", "a/deep/x"],
        ["a/deep/x/y/leaf.txt", "e"],
        ["link"],
        ["naïve\nline é.txt", "c/clone.bin"],
        ["a/medium.bin", "b", "c"],
        ["a/medium.bin"],
        ["b/source.bin"],
        ["c"],
        ["a/deep/x/note.md", "a/big.bin", "c/big-link.bin"],
    ]

    @Test(arguments: cases.indices)
    func aSplicedRemovalMatchesARescan(caseIndex: Int) async throws {
        let paths = Self.cases[caseIndex]
        let base = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let root = base.appending(path: "root", directoryHint: .isDirectory)
        let outside = base.appending(path: "trash", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try makeTree(at: root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let before = try await scan(root)
        let ids = paths.map { root.appending(path: $0).path }
        for id in ids { #expect(before.treeStore.node(id: id) != nil, "\(id)") }
        let spliced = try #require(try before.removingNodes(ids: ids))

        for (index, id) in before.treeStore.topLevelNodeIDs(from: ids).enumerated() {
            try FileManager.default.moveItem(atPath: id, toPath: outside.appending(path: "\(index)").path)
        }
        let after = try await scan(root)

        let expected = Dictionary(uniqueKeysWithValues: after.treeStore.allNodes.map { ($0.id, $0) })
        let actual = Dictionary(uniqueKeysWithValues: spliced.treeStore.allNodes.map { ($0.id, $0) })
        #expect(Set(actual.keys) == Set(expected.keys))
        for (id, node) in expected {
            guard let splicedNode = actual[id] else { continue }
            #expect(splicedNode.allocatedSize == node.allocatedSize, "allocated \(id)")
            #expect(splicedNode.logicalSize == node.logicalSize, "logical \(id)")
            #expect(splicedNode.descendantFileCount == node.descendantFileCount, "files \(id)")
            #expect(spliced.treeStore.children(of: id).map(\.id).sorted() == after.treeStore.children(of: id).map(\.id).sorted())
        }
        let a = spliced.aggregateStats
        let b = after.aggregateStats
        #expect(a.totalAllocatedSize == b.totalAllocatedSize)
        #expect(a.totalLogicalSize == b.totalLogicalSize)
        #expect(a.fileCount == b.fileCount)
        #expect(a.directoryCount == b.directoryCount)
        #expect(spliced.root.allocatedSize == after.root.allocatedSize)
    }

    /// Files of a few sizes, deep nesting, a hard link pair across folders, a clone (APFS), a symlink, an empty
    /// folder and a name with non-ASCII characters and a newline.
    private func makeTree(at root: URL) throws {
        let manager = FileManager.default
        for folder in ["a/deep/x/y", "b", "c", "e"] {
            try manager.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data(count: 3_000_000).write(to: root.appending(path: "a/big.bin"))
        try Data(repeating: 7, count: 70_000).write(to: root.appending(path: "a/medium.bin"))
        try Data(count: 10).write(to: root.appending(path: "a/deep/x/y/leaf.txt"))
        try Data(count: 5_000).write(to: root.appending(path: "a/deep/x/note.md"))
        try Data(count: 1_000_000).write(to: root.appending(path: "b/source.bin"))
        try manager.linkItem(at: root.appending(path: "b/source.bin"), to: root.appending(path: "b/hard.bin"))
        try manager.linkItem(at: root.appending(path: "a/big.bin"), to: root.appending(path: "c/big-link.bin"))
        // copyItem clones on APFS; elsewhere it's a plain copy, which the comparison handles the same way.
        try manager.copyItem(at: root.appending(path: "a/medium.bin"), to: root.appending(path: "c/clone.bin"))
        try manager.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "a"))
        try Data(count: 123).write(to: root.appending(path: "naïve\nline é.txt"))
    }

    private func scan(_ root: URL) async throws -> ScanSnapshot {
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        return try #require(finished)
    }
}
