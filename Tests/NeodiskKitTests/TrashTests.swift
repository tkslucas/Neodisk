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
        // On Windows a leading `//` starts a network share's path.
        #if !os(Windows)
        #expect(policy.refusal(forPath: "//Users/./me/Library/../Library", identity: nil) == .protectedLocation)
        #endif
    }

    #if os(Windows)
    @Test func windowsSpellingsOfAProtectedPathAreRefused() {
        let windows = TrashSafetyPolicy(protectedPaths: ["C:\\", "C:\\Users\\Me\\Documents"])
        for spelling in [
            "C:/Users/Me/Documents", "c:\\users\\me\\documents\\", "/C:/Users/Me/Documents",
            "C:\\Users\\Me\\.\\Pictures\\..\\Documents",
        ] {
            #expect(windows.refusal(forPath: spelling, identity: nil) == .protectedLocation, "\(spelling)")
        }
        // Drive roots and the folders that hold a protected one.
        #expect(windows.refusal(forPath: "C:/", identity: nil) == .protectedLocation)
        #expect(windows.refusal(forPath: "C:\\Users", identity: nil) == .protectedLocation)
        // `..` never climbs out of a drive, and other drives and what's inside are fine.
        #expect(windows.refusal(forPath: "C:/../../Users/Me/Documents", identity: nil) == .protectedLocation)
        #expect(windows.refusal(forPath: "C:/Users/Me/Documents/report.pdf", identity: nil) == nil)
        #expect(windows.refusal(forPath: "D:/Users/Me/Documents", identity: nil) == nil)
        #expect(windows.refusal(forPath: "C:/$Recycle.Bin/S-1-5-21/$R1.txt", identity: nil) == .alreadyInTrash)
        #expect(windows.refusal(forPath: "D:\\$RECYCLE.BIN", identity: nil) == .alreadyInTrash)
    }
    #endif

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
        #if os(Windows)
        let environment = ProcessInfo.processInfo.environment
        let systemDrive = environment["SystemDrive"] ?? "C:"
        #expect(live.refusal(forPath: systemDrive + "\\", identity: nil) == .protectedLocation)
        for name in ["SystemRoot", "ProgramFiles", "ProgramData"] {
            guard let path = environment[name] else {
                Issue.record("%\(name)% is not set")
                continue
            }
            #expect(live.refusal(forPath: path, identity: nil) == .protectedLocation, "\(name)")
        }
        let systemRoot = environment["SystemRoot"] ?? "C:\\Windows"
        #expect(live.refusal(forPath: systemRoot + "\\System32", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: systemRoot + "\\System32\\drivers\\etc\\hosts", identity: nil) == nil)
        #expect(live.refusal(forPath: home + "\\AppData\\Local", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: home + "\\AppData\\Local\\SomeApp", identity: nil) == nil)
        #else
        #expect(live.refusal(forPath: "/usr", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: "/tmp", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: "/usr/lib", identity: nil) == .protectedLocation)
        #endif
        #if os(macOS)
        #expect(live.refusal(forPath: "/private/tmp", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: "/private/var/folders", identity: nil) == .protectedLocation)
        #expect(live.refusal(forPath: "/System/Library", identity: nil) == .protectedLocation)
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            #expect(live.refusal(forPath: "/Volumes/" + volume, identity: nil) == .protectedLocation)
        }
        #expect(live.refusal(forPath: "/System/Volumes/Data" + home, identity: nil) == .protectedLocation)
        #endif
    }
}

@Suite struct TrashSafetyPolicyEdgeTests {
    @Test func unreadableFoldersAndUndecodableNamesAreRefused() {
        let policy = TrashSafetyPolicy(protectedPaths: [])
        let locked = FileNodeRecord(
            id: "/data/locked", url: URL(filePath: "/data/locked"), name: "locked", isDirectory: true,
            isSymbolicLink: false, allocatedSize: 0, logicalSize: 0, descendantFileCount: 0, lastModified: nil,
            isPackage: false, isAccessible: false, isSelfAccessible: false, isSynthetic: false, isAutoSummarized: false
        )
        #expect(policy.refusal(for: locked, scanRootID: "/data") == .unreadableFolder)
        let garbled = makeTestFileNode(id: "/data/caf\u{FFFD}.txt", name: "caf\u{FFFD}.txt")
        #expect(policy.refusal(for: garbled, scanRootID: "/data") == .undecodableName)
    }

    /// The mount table spells a volume by its real path; a scan reached through a symlink (/tmp on macOS, a
    /// linked folder) must still see that a folder holds it.
    @Test func aHolderReachedThroughASymlinkIsStillRefused() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-spelling-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real.appending(path: "holder/volume"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appending(path: "alias"), withDestinationURL: real)
        // As the mount table has it: the real path (/private/var/..., not /var/...).
        #if os(Windows)
        let volume = try #require(WindowsPath.resolved(real.appending(path: "holder/volume").path))
        let policy = TrashSafetyPolicy(protectedPaths: [volume])
        #else
        let volume = try #require(realpath(real.appending(path: "holder/volume").path, nil))
        defer { free(volume) }
        let policy = TrashSafetyPolicy(protectedPaths: [String(cString: volume)])
        #endif

        let alias = base.appending(path: "alias").path
        #expect(policy.refusal(forPath: alias + "/holder", identity: nil) == .protectedLocation)
        #expect(policy.refusal(forPath: alias + "/holder/volume", identity: nil) == .protectedLocation)
        #expect(policy.refusal(forPath: alias + "/holder/volume/file", identity: nil) == nil)
        // The link itself is an item of its own: it goes as the link, and holds nothing.
        #expect(policy.refusal(forPath: alias, identity: nil) == nil)

        // A large selection, checked folder by folder, says exactly what one-by-one checks say.
        let paths = [
            alias + "/holder", alias + "/holder/volume", alias + "/holder/volume/file", alias, real.path + "/holder",
            real.path + "/x.txt", "/Users/me/.Trash/old.zip", "/home/me/.local/share/Trash", "/", "/Users/me/a.bin",
        ]
        let nodes = paths.map { makeTestFileNode(id: $0, name: ($0 as NSString).lastPathComponent) }
        #expect(policy.refusals(for: nodes, scanRootID: "/scan") == nodes.map { policy.refusal(for: $0, scanRootID: "/scan") })
    }

    @Test func whatsInsideAPackageIsRefusedButThePackageIsNot() {
        let policy = TrashSafetyPolicy(protectedPaths: [])
        #expect(policy.refusal(forPath: "/Users/me/Apps/Tool.app", identity: nil) == nil)
        #expect(policy.refusal(forPath: "/Users/me/Pictures/Old.photoslibrary", identity: nil) == nil)
        #expect(policy.refusal(forPath: "/Users/me/notes.app.txt", identity: nil) == nil)
        #expect(policy.refusal(forPath: "/Users/me/.app/cache", identity: nil) == nil)
        #if os(macOS)
        #expect(policy.refusal(forPath: "/Users/me/Apps/Tool.app/Contents", identity: nil) == .insidePackage)
        #expect(policy.refusal(
            forPath: "/Library/Audio/Plug-Ins/Synth.COMPONENT/Contents/Resources/x.bin", identity: nil
        ) == .insidePackage)
        // Document packages, by the system's own verdict on the extension.
        #expect(policy.refusal(forPath: "/Users/me/Pictures/Old.photoslibrary/originals", identity: nil) == .insidePackage)
        #expect(policy.refusal(forPath: "/Users/me/Notes.rtfd/TXT.rtf", identity: nil) == .insidePackage)
        #else
        #expect(policy.refusal(forPath: "/home/me/site.app/node_modules", identity: nil) == nil)
        #endif
    }

    /// A folder the scan marked as a package (Finder's bundle bit) counts, whatever its name.
    @Test func whatsInsideAScannedPackageIsRefused() {
        func folder(_ path: String, package: Bool, _ children: [FileNodeRecord]) -> FileNodeRecord {
            FileNodeRecord.directory(
                id: path, url: URL(filePath: path, directoryHint: .isDirectory),
                name: (path as NSString).lastPathComponent, children: children, lastModified: nil,
                fileIdentity: nil, linkCount: 1, isPackage: package, isAccessible: true
            )
        }
        let inner = makeTestFileNode(id: "/scan/Odd Bundle/data.bin", name: "data.bin")
        let bundle = folder("/scan/Odd Bundle", package: true, [inner])
        let root = folder("/scan", package: false, [bundle])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [bundle], bundle.id: [inner]])
        let policy = TrashSafetyPolicy(protectedPaths: [])
        #expect(policy.refusal(for: inner, scanRootID: root.id, in: store) == .insidePackage)
        #expect(policy.refusal(for: bundle, scanRootID: root.id, in: store) == nil)
    }

    @Test func localizedUserFoldersComeFromUserDirs() {
        let contents = """
        # comment
        XDG_DESKTOP_DIR="$HOME/Schreibtisch"
        XDG_PICTURES_DIR="$HOME/Bilder"
        XDG_MUSIC_DIR="/srv/music"
        """
        let folders = TrashSafetyPolicy.xdgUserDirectories(homeDirectory: "/home/me", contents: contents)
        #expect(folders == ["/home/me/Schreibtisch", "/home/me/Bilder", "/srv/music"])
    }

    @Test func secretsAndCloudRootsAreProtected() {
        let live = TrashSafetyPolicy.live()
        let home = NSHomeDirectory()
        #expect(live.refusal(forPath: home + "/.ssh", identity: nil) == .protectedLocation)
        #if os(macOS)
        #expect(live.refusal(forPath: home + "/Library/Keychains", identity: nil) == .protectedLocation)
        #expect(live.refusal(
            forPath: home + "/Library/Mobile Documents/com~apple~CloudDocs", identity: nil
        ) == .protectedLocation)
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

    /// A reopened saved scan must verify like the fresh one it was saved from: files and folders alike.
    @Test func itemsOfAReopenedSavedScanVerifyAsUnchanged() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Folder/Nested"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appending(path: "small.txt"))
        try Data(count: 3_000_000).write(to: root.appending(path: "Folder/big.bin"))
        try Data(count: 50).write(to: root.appending(path: "Folder/Nested/note.md"))

        let reopened = try ScanSnapshotCodec.decode(ScanSnapshotCodec.encode(try await scan(root)))
        let store = reopened.treeStore
        let nodes = store.indexedNodeIDs().compactMap { store.node(id: $0) }.filter { $0.id != reopened.root.id }
        #expect(nodes.contains { $0.isDirectory } && nodes.contains { !$0.isDirectory })
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

        // A big file edited in place keeps its inode but isn't what the scan saw.
        let edited = root.appending(path: "edited.bin")
        try Data(count: 3_000_000).write(to: edited)
        let rescanned = try await scan(root)
        let editedNode = try #require(rescanned.treeStore.node(id: edited.path))
        #expect(TrashMover.verify(editedNode) == nil)
        let handle = try FileHandle(forWritingTo: edited)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 10))
        try handle.close()
        #expect(TrashMover.verify(editedNode) == .changedSinceScan)

        // A small file rewritten with other content.
        try Data(count: 20).write(to: small)
        #expect(TrashMover.verify(smallNode) == .changedSinceScan)
        // A big file replaced by a new one at the same path (an atomic save); Linux may hand the new file the
        // old inode, so its size and date catch it.
        try FileManager.default.removeItem(at: big)
        try Data(count: 3_100_000).write(to: big)
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

@Suite struct TrashMoverLinkTests {
    /// A symlink goes to the Trash as the link itself; what it points at stays.
    @Test func aSymlinkIsTrashedAsTheLinkNotItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-link-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appending(path: "Real"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 10).write(to: root.appending(path: "Real/keep.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"), withDestinationURL: root.appending(path: "Real")
        )
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let snapshot = try #require(finished)
        let link = try #require(snapshot.treeStore.node(id: root.appending(path: "link").path))
        #expect(link.isSymbolicLink)

        let received = PathBox()
        let mover = TrashMover(policy: TrashSafetyPolicy(protectedPaths: [])) { url in
            received.path = url.path
            try FileManager.default.removeItem(at: url)
            return nil
        }
        #expect(mover.move(link, scanRootID: snapshot.root.id) == .success(nil))
        #expect(received.path == root.appending(path: "link").path)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Real/keep.txt").path))
    }
}

private final class PathBox: @unchecked Sendable {
    var path: String?
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

#if canImport(Darwin)
@Suite struct TrashLockedTests {
    @Test func lockedFileReportsLockedNotPermission() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "trash-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "locked.txt")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(TrashMover.isLocked(file.path))
        #expect(!TrashMover.isLocked(dir.path))
    }
}
#endif
