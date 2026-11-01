import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

@Suite struct TrashConfirmationTests {
    private func node(_ path: String, size: Int64 = 1_000, linkCount: UInt64 = 1, dataless: Bool = false) -> FileNodeRecord {
        FileNodeRecord(
            id: path, url: URL(filePath: path), name: (path as NSString).lastPathComponent, isDirectory: false,
            isSymbolicLink: false, allocatedSize: size, logicalSize: size, descendantFileCount: 1, lastModified: nil,
            linkCount: linkCount, isPackage: false, isAccessible: true, isSelfAccessible: true, isSynthetic: false,
            isAutoSummarized: false, isDataless: dataless
        )
    }

    @Test func listsThreePathsAndCountsTheRest() {
        let nodes = (1...5).map { node("/data/file\($0)") }
        let confirmation = TrashConfirmation(nodes: nodes, homeDirectory: "/Users/me")
        #expect(confirmation.title.contains("5"))
        #expect(confirmation.paths.contains("/data/file3"))
        #expect(!confirmation.paths.contains("/data/file4"))
        #expect(confirmation.paths.contains("2"))
        #expect(confirmation.notes.count == 1)
    }

    @Test func warnsAboutCloudSharedStorageAndOldScans() {
        let home = "/Users/me"
        let cloud = TrashConfirmation(nodes: [node(home + "/Library/CloudStorage/Drive-x/a")], homeDirectory: home)
        #expect(cloud.notes.count == 2)
        let dataless = TrashConfirmation(nodes: [node("/data/a", dataless: true)], homeDirectory: home)
        #expect(dataless.notes.count == 2)
        let linked = TrashConfirmation(nodes: [node("/data/a", linkCount: 2)], homeDirectory: home)
        #expect(linked.notes.count == 2)
        let now = Date()
        let old = TrashConfirmation(nodes: [node("/data/a")], scannedAt: now.addingTimeInterval(-86_400 * 3), now: now, homeDirectory: home)
        #expect(old.notes.count == 2)
        let fresh = TrashConfirmation(nodes: [node("/data/a")], scannedAt: now.addingTimeInterval(-60), now: now, homeDirectory: home)
        #expect(fresh.notes.count == 1)
    }
}


@Suite struct CleanupPileTests {
    private func store(_ nodes: [FileNodeRecord]) -> FileTreeStore {
        let root = FileNodeRecord.directory(
            id: "/data", url: URL(filePath: "/data", directoryHint: .isDirectory), name: "data", children: nodes,
            lastModified: nil, fileIdentity: nil, linkCount: 1, isPackage: false, isAccessible: true
        )
        return FileTreeStore(root: root, childrenByID: [root.id: nodes])
    }

    private func file(_ name: String, size: Int64, inode: UInt64? = nil) -> FileNodeRecord {
        FileNodeRecord(
            id: "/data/" + name, url: URL(filePath: "/data/" + name), name: name, isDirectory: false,
            isSymbolicLink: false, allocatedSize: size, logicalSize: size, descendantFileCount: 1, lastModified: nil,
            fileIdentity: inode.map { .fileSystem(device: 1, inode: $0) }, isPackage: false, isAccessible: true,
            isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false
        )
    }

    /// Paths are ids: after a rescan the same path can hold another item, which mustn't inherit the pick.
    @Test func itemsThatBecameSomethingElseLeaveOnReconcile() {
        var pile = CleanupPile()
        pile.add(["/data/a", "/data/b", "/data/c"], in: store([
            file("a", size: 10), file("b", size: 5_000_000, inode: 7), file("c", size: 3),
        ]))
        let changed = pile.reconcile(with: store([
            file("a", size: 99), file("b", size: 5_000_000, inode: 8), file("c", size: 3),
        ]))
        #expect(changed == 2)
        #expect(pile.itemIDs == ["/data/c"])
    }

    @Test func viewsOnARemovedItemLandOnTheFolderAboveTheOutermostCut() {
        func folder(_ path: String, _ children: [FileNodeRecord]) -> FileNodeRecord {
            FileNodeRecord.directory(
                id: path, url: URL(filePath: path, directoryHint: .isDirectory),
                name: (path as NSString).lastPathComponent, children: children, lastModified: nil,
                fileIdentity: nil, linkCount: 1, isPackage: false, isAccessible: true
            )
        }
        let leaf = file("x/y/leaf", size: 1)
        let y = folder("/data/x/y", [leaf])
        let x = folder("/data/x", [y])
        let root = folder("/data", [x])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [x], x.id: [y], y.id: [leaf]])

        #expect(store.survivor(of: leaf.id, removing: [y.id]) == x.id)
        #expect(store.survivor(of: leaf.id, removing: [y.id, x.id]) == root.id)
        #expect(store.survivor(of: y.id, removing: [leaf.id]) == y.id)
        #expect(store.survivor(of: "/elsewhere", removing: [y.id]) == nil)
    }

    /// A large selection (⌘A on a big list) adds in one top-level pass, not a walk of the pile per item.
    @Test func fiftyThousandIDsAddWithinABudget() {
        var folders: [FileNodeRecord] = []
        var childrenByID: [String: [FileNodeRecord]] = [:]
        for f in 0..<100 {
            let files = (0..<500).map { file("d\(f)/f\($0)", size: 1) }
            let folder = FileNodeRecord.directory(
                id: "/data/d\(f)", url: URL(filePath: "/data/d\(f)", directoryHint: .isDirectory), name: "d\(f)",
                children: files, lastModified: nil, fileIdentity: nil, linkCount: 1, isPackage: false,
                isAccessible: true
            )
            folders.append(folder)
            childrenByID[folder.id] = files
        }
        let root = FileNodeRecord.directory(
            id: "/data", url: URL(filePath: "/data", directoryHint: .isDirectory), name: "data", children: folders,
            lastModified: nil, fileIdentity: nil, linkCount: 1, isPackage: false, isAccessible: true
        )
        childrenByID[root.id] = folders
        let store = FileTreeStore(root: root, childrenByID: childrenByID)
        let fileIDs = childrenByID.filter { $0.key != root.id }.values.flatMap { $0.map(\.id) }
        #expect(fileIDs.count == 50_000)

        var pile = CleanupPile()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            pile.add(fileIDs, in: store)
            // Re-adding is a no-op; a folder then absorbs its 500 files.
            pile.add(fileIDs, in: store)
            pile.add(["/data/d0"], in: store)
            _ = pile.reconcile(with: store)
            for id in fileIDs { _ = pile.collectedItem(containing: id, in: store) }
        }
        #expect(pile.itemIDs.count == 49_501)
        #expect(pile.collectedItem(containing: "/data/d0/f7", in: store) == "/data/d0")
        #expect(elapsed < .seconds(10), "\(elapsed)")
    }
}
