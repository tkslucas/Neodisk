import Foundation
import Testing
@testable import NeodiskKit

@Suite struct ScanChangeListTests {
    @Test func testClassifiesAddedDeletedGrownAndShrunk() throws {
        let previous = makeStore(files: [
            ("kept.txt", 100, nil),
            ("grew.bin", 200, nil),
            ("shrank.bin", 300, nil),
            ("gone.bin", 400, nil)
        ])
        let current = makeStore(files: [
            ("kept.txt", 100, nil),
            ("grew.bin", 260, nil),
            ("shrank.bin", 250, nil),
            ("fresh.bin", 500, nil)
        ])

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(entry(list, "/base/fresh.bin")?.kind == .added)
        #expect(entry(list, "/base/fresh.bin")?.delta == 500)
        #expect(entry(list, "/base/gone.bin")?.kind == .deleted)
        #expect(entry(list, "/base/gone.bin")?.delta == -400)
        #expect(entry(list, "/base/gone.bin")?.nodeID == nil)
        #expect(entry(list, "/base/grew.bin")?.kind == .grown)
        #expect(entry(list, "/base/grew.bin")?.delta == 60)
        #expect(entry(list, "/base/shrank.bin")?.kind == .shrunk)
        #expect(entry(list, "/base/shrank.bin")?.delta == -50)
        #expect(entry(list, "/base/kept.txt") == nil)
        #expect(list.totalEntryCount == 4)
        #expect(list.addedBytes == 560)
        #expect(list.removedBytes == 450)
        #expect(list.renamedCount == 0)
    }

    @Test func testRenamedFileIsOneEntryNotAddPlusDelete() throws {
        let identity = FileIdentity(device: 1, inode: 10)
        let previous = makeStore(files: [("old-name.mov", 900, identity)])
        let current = makeStore(files: [("new-name.mov", 900, identity)])

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(list.entries.count == 1)
        let renamed = try #require(entry(list, "/base/new-name.mov"))
        #expect(renamed.kind == .renamed)
        #expect(renamed.delta == 0)
        #expect(renamed.previousPath == "/base/old-name.mov")
        #expect(renamed.nodeID == "/base/new-name.mov")
        #expect(list.renamedCount == 1)
        #expect(list.addedBytes == 0)
        #expect(list.removedBytes == 0)
    }

    @Test func testMovedAndChangedFileKeepsItsNetDelta() throws {
        // The exact pipeline matches identity even when the size changed —
        // unlike the hashed baseline, real paths have no collision risk.
        let identity = FileIdentity(device: 1, inode: 10)
        let previous = makeStore(files: [("old.sqlite", 500, identity)])
        let current = makeStore(files: [("moved.sqlite", 620, identity)])

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(list.entries.count == 1)
        let renamed = try #require(entry(list, "/base/moved.sqlite"))
        #expect(renamed.kind == .renamed)
        #expect(renamed.delta == 120)
        #expect(renamed.previousPath == "/base/old.sqlite")
    }

    @Test func testHardLinkedFilesNeverMatchAsRenames() throws {
        let identity = FileIdentity(device: 1, inode: 10)
        let previous = makeStore(files: [("link-a", 500, identity, 2)])
        let current = makeStore(files: [("link-b", 500, identity, 2)])

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(entry(list, "/base/link-b")?.kind == .added)
        #expect(entry(list, "/base/link-a")?.kind == .deleted)
        #expect(list.renamedCount == 0)
    }

    @Test func testFullyAddedAndDeletedSubtreesCollapseToOneEntry() throws {
        let previousDirChildren = [
            makeFile("/base/old-dir/a.bin", 100),
            makeFile("/base/old-dir/b.bin", 200)
        ]
        let previous = makeStore(directories: [("old-dir", previousDirChildren)])
        let currentDirChildren = [
            makeFile("/base/new-dir/x.bin", 300),
            makeFile("/base/new-dir/y.bin", 400)
        ]
        let current = makeStore(directories: [("new-dir", currentDirChildren)])

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(list.entries.count == 2)
        let added = try #require(entry(list, "/base/new-dir"))
        #expect(added.kind == .added)
        #expect(added.isDirectory)
        #expect(added.delta == 700)
        let deleted = try #require(entry(list, "/base/old-dir"))
        #expect(deleted.kind == .deleted)
        #expect(deleted.delta == -300)
        #expect(entry(list, "/base/new-dir/x.bin") == nil)
        #expect(entry(list, "/base/old-dir/a.bin") == nil)
    }

    @Test func testMovedDirectoryIsOneRenamedEntry() throws {
        let dirIdentity = FileIdentity(device: 1, inode: 77)
        let fileIdentity = FileIdentity(device: 1, inode: 78)
        let previous = makeStore(directories: [
            ("old-dir", [makeFile("/base/old-dir/movie.mov", 800, identity: fileIdentity)], dirIdentity)
        ])
        let current = makeStore(directories: [
            ("new-dir", [makeFile("/base/new-dir/movie.mov", 800, identity: fileIdentity)], dirIdentity)
        ])

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(list.entries.count == 1)
        let renamed = try #require(entry(list, "/base/new-dir"))
        #expect(renamed.kind == .renamed)
        #expect(renamed.previousPath == "/base/old-dir")
        #expect(renamed.delta == 0)
        // The file inside moved with its directory: no entry on either side.
        #expect(entry(list, "/base/new-dir/movie.mov") == nil)
        #expect(entry(list, "/base/old-dir/movie.mov") == nil)
    }

    @Test func testMovedDirectoryWithInnerChangeCarriesTheNetDelta() throws {
        let dirIdentity = FileIdentity(device: 1, inode: 77)
        let previous = makeStore(directories: [
            ("old-dir", [
                makeFile("/base/old-dir/kept.bin", 500),
                makeFile("/base/old-dir/gone.bin", 200)
            ], dirIdentity)
        ])
        let current = makeStore(directories: [
            ("new-dir", [makeFile("/base/new-dir/kept.bin", 500)], dirIdentity)
        ])

        let list = ScanChangeList.build(current: current, previous: previous)

        // One renamed entry summarizes the move and the deletion inside it.
        #expect(list.entries.count == 1)
        let renamed = try #require(entry(list, "/base/new-dir"))
        #expect(renamed.kind == .renamed)
        #expect(renamed.delta == -200)
        #expect(entry(list, "/base/old-dir/gone.bin") == nil)
    }

    @Test func testEntriesSortByDeltaMagnitudeAndCapHonorsLimit() throws {
        let previous = makeStore(files: [("shrank.bin", 300, nil)])
        let current = makeStore(files: [
            ("shrank.bin", 250, nil),
            ("big.bin", 900, nil),
            ("small.bin", 10, nil)
        ])

        let list = ScanChangeList.build(current: current, previous: previous, entryLimit: 2)

        #expect(list.totalEntryCount == 3)
        #expect(list.entries.count == 2)
        #expect(list.entries[0].path == "/base/big.bin")
        #expect(list.entries[1].path == "/base/shrank.bin")
    }

    @Test func testSyntheticNodesAreIgnored() throws {
        let synthetic = FileNodeRecord(
            id: "/base/System Data",
            url: URL(filePath: "/base/System Data"),
            name: "System Data",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 12_345,
            logicalSize: 12_345,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let previous = makeStore(files: [("kept.txt", 100, nil)])
        let root = makeTestDirectoryNode(
            id: "/base", name: "base",
            children: [makeFile("/base/kept.txt", 100), synthetic]
        )
        let current = FileTreeStore(
            root: root,
            childrenByID: [root.id: [makeFile("/base/kept.txt", 100), synthetic]]
        )

        let list = ScanChangeList.build(current: current, previous: previous)

        #expect(entry(list, "/base/System Data") == nil)
    }

    // MARK: - Fixtures

    private func entry(_ list: ScanChangeList, _ path: String) -> ScanChangeEntry? {
        list.entries.first { $0.path == path }
    }

    private func makeFile(
        _ id: String, _ size: Int64, identity: FileIdentity? = nil, linkCount: UInt64 = 1
    ) -> FileNodeRecord {
        makeTestFileNode(
            id: id,
            name: (id as NSString).lastPathComponent,
            size: size,
            fileIdentity: identity,
            linkCount: linkCount
        )
    }

    /// Flat tree of files under /base. Tuples: name, size, identity, and an
    /// optional link count.
    private func makeStore(files: [(String, Int64, FileIdentity?)]) -> FileTreeStore {
        makeStore(files: files.map { ($0.0, $0.1, $0.2, 1) })
    }

    private func makeStore(files: [(String, Int64, FileIdentity?, UInt64)]) -> FileTreeStore {
        let children = files.map { name, size, identity, linkCount in
            makeFile("/base/\(name)", size, identity: identity, linkCount: linkCount)
        }
        let root = makeTestDirectoryNode(id: "/base", name: "base", children: children)
        return FileTreeStore(root: root, childrenByID: [root.id: children])
    }

    /// Tree of directories under /base, each with the given children.
    private func makeStore(
        directories: [(String, [FileNodeRecord], FileIdentity?)]
    ) -> FileTreeStore {
        var childrenByID: [String: [FileNodeRecord]] = [:]
        var topLevel: [FileNodeRecord] = []
        for (name, children, identity) in directories {
            let dir = makeTestDirectoryNode(
                id: "/base/\(name)", name: name, children: children, fileIdentity: identity
            )
            childrenByID[dir.id] = children
            topLevel.append(dir)
        }
        let root = makeTestDirectoryNode(id: "/base", name: "base", children: topLevel)
        childrenByID[root.id] = topLevel
        return FileTreeStore(root: root, childrenByID: childrenByID)
    }

    private func makeStore(
        directories: [(String, [FileNodeRecord])]
    ) -> FileTreeStore {
        makeStore(directories: directories.map { ($0.0, $0.1, nil) })
    }
}
