import Foundation
import Testing
@testable import NeodiskKit

@Suite struct TokenCountTests {
    let counter = HeuristicTokenCounter()

    @Test func countsWordsPunctuationAndCamelCase() {
        #expect(counter.countTokens(in: "") == 0)
        #expect(counter.countTokens(in: "hello world") == 2)
        #expect(counter.countTokens(in: "TreemapScene") == 2)
        // 12 words, 2 punctuation runs, 1 line break.
        let prose = "The quick brown fox jumps over the lazy dog, then naps in the sun.\n"
        #expect((14...17).contains(counter.countTokens(in: prose)))
    }

    @Test func detectsBinaryAndDecodesUTF16() {
        let binary: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]
        #expect(binary.withUnsafeBytes { TokenCountService.countText($0, counter: counter) } == nil)

        var utf16: [UInt8] = [0xFF, 0xFE]
        utf16 += Array("hello world".data(using: .utf16LittleEndian)!)
        #expect(utf16.withUnsafeBytes { TokenCountService.countText($0, counter: counter) } == 2)
    }

    @Test func countsTextFilesSkipsBinaryAndCachesByDate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenCountTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let notes = try writeFile(dir, "notes.md", Data("hello world".utf8))
        let blob = try writeFile(dir, "blob.dat", Data([0, 1, 2, 3]))
        let image = try writeFile(dir, "photo.png", Data("not really an image".utf8))
        let root = makeTestDirectoryNode(id: dir.path, name: "dir", children: [notes, blob, image])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [notes, blob, image]])
        let cache = TokenCountCache()

        let tally = try #require(TokenCountService.count(store: store, cache: cache))
        #expect(tally.tokensByID == [notes.id: 2])
        #expect(tally.nonTextFileCount == 1)

        // Same size and date: served from the cache, not reread.
        try Data("a b c d e f".utf8).write(to: URL(filePath: notes.id))
        let cached = try #require(TokenCountService.count(store: store, cache: cache))
        #expect(cached.tokensByID[notes.id] == 2)

        let touched = makeTestFileNode(
            id: notes.id, name: notes.name, size: notes.logicalSize,
            lastModified: notes.lastModified!.addingTimeInterval(1)
        )
        let rescanned = FileTreeStore(root: root, childrenByID: [root.id: [touched]])
        #expect(TokenCountService.count(store: rescanned, cache: cache)?.tokensByID[notes.id] == 6)
    }

    @Test func cancelledCountReturnsNil() {
        let file = makeTestFileNode(id: "/nonexistent/a.md", name: "a.md", size: 10, lastModified: Date())
        let store = FileTreeStore(root: makeTestDirectoryNode(id: "/nonexistent", name: "x", children: [file]),
                                  childrenByID: ["/nonexistent": [file]])
        #expect(TokenCountService.count(store: store, isCancelled: { true }) == nil)
    }

    @Test func reweightedSumsFoldersAndResortsSiblings() {
        let big = makeTestFileNode(id: "/r/big.bin", name: "big.bin", size: 1_000)
        let small = makeTestFileNode(id: "/r/docs/small.md", name: "small.md", size: 10)
        let other = makeTestFileNode(id: "/r/docs/other.md", name: "other.md", size: 20)
        let docs = makeTestDirectoryNode(id: "/r/docs", name: "docs", children: [small, other])
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [big, docs])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [big, docs], docs.id: [other, small]])
        let tokens = [small.id: 300, other.id: 100]

        let reweighted = store.reweighted { Int64(tokens[$0.id] ?? 0) }

        #expect(reweighted.root.allocatedSize == 400)
        #expect(reweighted.aggregateStats.totalAllocatedSize == 400)
        #expect(reweighted.node(id: docs.id)?.allocatedSize == 400)
        #expect(reweighted.node(id: big.id)?.allocatedSize == 0)
        #expect(reweighted.children(of: root.id).map(\.id) == [docs.id, big.id])
        #expect(reweighted.children(of: docs.id).map(\.id) == [small.id, other.id])
        #expect(reweighted.parent(of: small.id)?.id == docs.id)
    }

    @Test func matchesAgentInstructionFiles() {
        for name in ["CLAUDE.md", "AGENTS.md", "soul.md", ".cursorrules", "style.mdc"] {
            #expect(AgentInstructionFiles.matches(makeTestFileNode(id: "/p/\(name)", name: name)))
        }
        #expect(!AgentInstructionFiles.matches(makeTestFileNode(id: "/p/README.md", name: "README.md")))
    }

    private func writeFile(_ dir: URL, _ name: String, _ data: Data) throws -> FileNodeRecord {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return makeTestFileNode(id: url.path, name: name, size: Int64(data.count), lastModified: modified)
    }
}
