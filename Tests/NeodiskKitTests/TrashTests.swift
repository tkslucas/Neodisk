import Foundation
import Testing
@testable import NeodiskKit

@Suite struct TrashSafetyPolicyTests {
    private let policy = TrashSafetyPolicy(protectedPaths: [
        "/", "/Applications", "/Users", "/Users/me", "/Users/me/Library", "/Users/me/Library/Caches",
    ])

    @Test func protectedLocationsAndTheirHoldersAreRefused() {
        #expect(policy.refusal(forPath: "/Applications", identity: nil) == .protectedLocation)
        #expect(policy.refusal(forPath: "/Users/me", identity: nil) == .protectedLocation)
        // Holds ~/Library, so it would take it along.
        #expect(policy.refusal(forPath: "/Users", identity: nil) == .protectedLocation)
    }

    @Test func spellingsOfAProtectedPathAreRefused() {
        #expect(policy.refusal(forPath: "/applications", identity: nil) == .protectedLocation)
        #expect(policy.refusal(forPath: "/USERS/ME/library/", identity: nil) == .protectedLocation)
        #expect(policy.refusal(forPath: "//Users/./me/Library/../Library", identity: nil) == .protectedLocation)
    }

    @Test func whatsInsideProtectedLocationsIsAllowed() {
        #expect(policy.refusal(forPath: "/Applications/Some App.app", identity: nil) == nil)
        #expect(policy.refusal(forPath: "/Users/me/Library/Caches/com.example", identity: nil) == nil)
        #expect(policy.refusal(forPath: "/Users/me/Projects", identity: nil) == nil)
        // A near-prefix isn't a parent.
        #expect(policy.refusal(forPath: "/Users/me/LibraryOld", identity: nil) == nil)
    }

    @Test func aProtectedFolderIsRecognizedByIdentity() {
        let identity = FileIdentity.fileSystem(device: 7, inode: 42)
        let byIdentity = TrashSafetyPolicy(protectedPaths: ["/"], protectedIdentities: [identity])
        #expect(byIdentity.refusal(forPath: "/Somewhere/Else", identity: identity) == .protectedLocation)
        #expect(byIdentity.refusal(forPath: "/Somewhere/Else", identity: .fileSystem(device: 7, inode: 43)) == nil)
    }

    @Test func itemsAlreadyInATrashAreRefused() {
        #expect(policy.refusal(forPath: "/Users/me/.Trash/old.zip", identity: nil) == .alreadyInTrash)
        #expect(policy.refusal(forPath: "/Volumes/Disk/.Trashes/501/x", identity: nil) == .alreadyInTrash)
        #expect(policy.refusal(forPath: "/home/me/.local/share/Trash/files/x", identity: nil) == .alreadyInTrash)
        #expect(policy.refusal(forPath: "/media/disk/.Trash-1000/files/x", identity: nil) == .alreadyInTrash)
        #expect(policy.refusal(forPath: "/Users/me/Trash notes.txt", identity: nil) == nil)
    }

    @Test func syntheticNodesAndTheScanRootAreRefused() {
        let file = makeTestFileNode(id: "/Users/me/Projects/a.bin", name: "a.bin")
        #expect(policy.refusal(for: file, scanRootID: "/Users/me/Projects") == nil)
        #expect(policy.refusal(for: file, scanRootID: file.id) == .scanRoot)

        let synthetic = FileNodeRecord(
            id: "free-space", url: URL(filePath: "/"), name: "Free", isDirectory: false, isSymbolicLink: false,
            allocatedSize: 1, logicalSize: 1, descendantFileCount: 0, lastModified: nil, isPackage: false,
            isAccessible: true, isSelfAccessible: true, isSynthetic: true, isAutoSummarized: false
        )
        #expect(policy.refusal(for: synthetic, scanRootID: "/") == .notAFile)
    }

    @Test func theLivePolicyProtectsHomeAndSystemButNotTheirContents() {
        let live = TrashSafetyPolicy.live()
        let home = NSHomeDirectory()
        #expect(live.refusal(forPath: home, identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: home + "/Documents", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: home + "/Documents/report.pdf", identity: nil) == nil)
        #expect(live.refusal(forPath: "/usr", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: "/tmp", identity: nil) == .protectedLocation)
        #if os(macOS)
        #expect(live.refusal(forPath: "/private/tmp", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: "/System/Volumes/Data" + home, identity: nil) == .protectedLocation)
        #endif
    }
}

@Suite struct TrashMoverTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func scan(_ root: URL) async throws -> ScanSnapshot {
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        return try #require(finished)
    }

    /// The check must read identities exactly as the scanner wrote them, or every move would be refused.
    @Test func everyScannedItemVerifiesAsUnchanged() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Folder/Nested"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appending(path: "small.txt"))
        try Data(count: 3_000_000).write(to: root.appending(path: "Folder/big.bin"))
        try Data(count: 50).write(to: root.appending(path: "Folder/Nested/note.md"))
        try FileManager.default.linkItem(
            at: root.appending(path: "small.txt"), to: root.appending(path: "Folder/hardlink.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"), withDestinationURL: root.appending(path: "Folder")
        )

        let snapshot = try await scan(root)
        let nodes = snapshot.treeStore.indexedNodeIDs().compactMap { snapshot.treeStore.node(id: $0) }
        #expect(nodes.count >= 7)
        for node in nodes where !node.isSynthetic {
            #expect(TrashMover.verify(node) == nil, "\(node.path)")
        }
    }

    @Test func replacedEditedAndMissingItemsAreCaught() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let small = root.appending(path: "small.txt")
        let big = root.appending(path: "big.bin")
        let gone = root.appending(path: "gone.txt")
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try Data(count: 10).write(to: small)
        try Data(count: 3_000_000).write(to: big)
        try Data(count: 5).write(to: gone)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let snapshot = try await scan(root)
        let store = snapshot.treeStore
        let smallNode = try #require(store.node(id: small.path))
        let bigNode = try #require(store.node(id: big.path))
        let goneNode = try #require(store.node(id: gone.path))
        let folderNode = try #require(store.node(id: folder.path))

        // A small file rewritten with other content.
        try Data(count: 20).write(to: small)
        #expect(TrashMover.verify(smallNode) == .changedSinceScan)
        // A big file replaced by a new one at the same path (an atomic save).
        try FileManager.default.removeItem(at: big)
        try Data(count: 3_000_000).write(to: big)
        #expect(TrashMover.verify(bigNode) == .changedSinceScan)
        // A folder replaced by a file.
        try FileManager.default.removeItem(at: folder)
        try Data(count: 1).write(to: folder)
        #expect(TrashMover.verify(folderNode) == .changedSinceScan)
        try FileManager.default.removeItem(at: gone)
        #expect(TrashMover.verify(goneNode) == .missing)
    }

    @Test func moveRefusesBeforeTouchingTheDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "keep.txt")
        try Data(count: 10).write(to: file)
        let snapshot = try await scan(root)
        let node = try #require(snapshot.treeStore.node(id: file.path))

        let calls = CallCounter()
        let protecting = TrashMover(policy: TrashSafetyPolicy(protectedPaths: [file.path])) { _ in
            calls.increment()
            return nil
        }
        #expect(protecting.move(node, scanRootID: snapshot.root.id) == .failure(.refused(.protectedLocation)))
        #expect(calls.value == 0)

        try Data(count: 99).write(to: file)
        let permissive = TrashMover(policy: TrashSafetyPolicy(protectedPaths: [])) { _ in
            calls.increment()
            return nil
        }
        #expect(permissive.move(node, scanRootID: snapshot.root.id) == .failure(.changedSinceScan))
        #expect(calls.value == 0)
    }

    @Test func moveHandsUnchangedItemsToTheTrashAndReportsItsErrors() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeTrash = root.appending(path: "fake-trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let file = root.appending(path: "old.log")
        try Data(count: 10).write(to: file)
        let snapshot = try await scan(root)
        let node = try #require(snapshot.treeStore.node(id: file.path))

        let mover = TrashMover(policy: TrashSafetyPolicy(protectedPaths: [])) { url in
            let destination = fakeTrash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let result = mover.move(node, scanRootID: snapshot.root.id)
        #expect(result == .success(fakeTrash.appending(path: "old.log")))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try Data(count: 10).write(to: file)
        let rescanned = try await scan(root)
        let failing = TrashMover(policy: TrashSafetyPolicy(protectedPaths: [])) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        let renode = try #require(rescanned.treeStore.node(id: file.path))
        guard case .failure(.systemError) = failing.move(renode, scanRootID: rescanned.root.id) else {
            Issue.record("expected a system error")
            return
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct SnapshotRemovalTests {
    @Test func removingNodesShrinksAncestorsAndPrunesTheirWarnings() throws {
        let leaf = makeTestFileNode(id: "/root/folder/file.txt", name: "file.txt", size: 12)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [leaf])
        let sibling = makeTestFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 4)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [folder, sibling], folder.id: [leaf]])
        let snapshot = makeTestSnapshot(root: root, store: store, warnings: [
            ScanWarning(path: "/root/folder/locked", message: "denied", category: .permissionDenied),
            ScanWarning(path: "/root/other", message: "denied", category: .permissionDenied),
        ])

        let updated = try #require(try snapshot.removingNodes(ids: [leaf.id, folder.id]))
        #expect(updated.treeStore.node(id: folder.id) == nil)
        #expect(updated.root.allocatedSize == 4)
        #expect(updated.aggregateStats.fileCount == 1)
        #expect(updated.scanWarnings.map(\.path) == ["/root/other"])
        #expect(updated.id != snapshot.id)
        #expect(updated.target == snapshot.target)
    }

    @Test func removingNodesNeverRemovesTheRootOrUnknownIDs() throws {
        let child = makeTestFileNode(id: "/root/a", name: "a", size: 3)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [child])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [child]])
        let snapshot = makeTestSnapshot(root: root, store: store)
        #expect(try snapshot.removingNodes(ids: [root.id]) == nil)
        #expect(try snapshot.removingNodes(ids: ["/elsewhere"]) == nil)
    }

    @Test func removingAHardLinkOwnerHandsItsSizeToTheSurvivingLink() throws {
        let identity = FileIdentity.fileSystem(device: 1, inode: 99)
        let first = makeTestFileNode(id: "/root/a/link", name: "link", size: 100, fileIdentity: identity, linkCount: 2)
        let second = makeTestFileNode(id: "/root/b/link", name: "link", size: 100, fileIdentity: identity, linkCount: 2)
        let folderA = makeTestDirectoryNode(id: "/root/a", name: "a", children: [first])
        let folderB = makeTestDirectoryNode(id: "/root/b", name: "b", children: [second])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folderA, folderB])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [folderA, folderB], folderA.id: [first], folderB.id: [second],
        ])
        let deduped = try SharedSizeDeduplication.rebalancedStore(store, cancellationCheck: {})
        let snapshot = makeTestSnapshot(root: deduped.root, store: deduped)
        #expect(snapshot.root.allocatedSize == 100)

        let owner = deduped.node(id: first.id)!.allocatedSize > 0 ? first.id : second.id
        let survivor = owner == first.id ? second.id : first.id
        let updated = try #require(try snapshot.removingNodes(ids: [owner]))
        #expect(updated.treeStore.node(id: survivor)?.allocatedSize == 100)
        #expect(updated.root.allocatedSize == 100)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
