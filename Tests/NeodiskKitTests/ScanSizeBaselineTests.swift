import Foundation
import Testing
@testable import NeodiskKit

@Suite struct ScanSizeBaselineTests {
    @Test func testBaselineReportsPreviousSizesAndDeltas() throws {
        let oldFile = makeTestFileNode(id: "/base/report.pdf", name: "report.pdf", size: 100)
        let root = makeTestDirectoryNode(id: "/base", name: "base", children: [oldFile])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [oldFile]])
        let snapshot = makeTestSnapshot(target: makeTestTarget("/base"), root: root, store: store)

        let baseline = ScanSizeBaseline(snapshot: snapshot)

        #expect(baseline.targetID == "/base")
        #expect(baseline.allocatedSize(forNodeID: "/base/report.pdf") == 100)
        #expect(baseline.allocatedSize(forNodeID: "/base") == 100)
        #expect(baseline.allocatedSize(forNodeID: "/base/new.bin") == nil)

        let grown = makeTestFileNode(id: "/base/report.pdf", name: "report.pdf", size: 160)
        #expect(baseline.sizeDelta(for: grown) == 60)
        let brandNew = makeTestFileNode(id: "/base/new.bin", name: "new.bin", size: 42)
        #expect(baseline.sizeDelta(for: brandNew) == 42)
    }

    @Test func testRenamedNodeDiffsAgainstItsOldEntry() throws {
        let identity = FileIdentity(device: 7, inode: 42)
        let oldFile = makeTestFileNode(
            id: "/base/old-name.mov", name: "old-name.mov", size: 500, fileIdentity: identity
        )
        let baseline = makeBaseline(children: [oldFile])

        // Same identity, different path, same size: a move, not an add.
        let renamed = makeTestFileNode(
            id: "/base/new-name.mov", name: "new-name.mov", size: 500, fileIdentity: identity
        )
        #expect(baseline.movedSourceSize(for: renamed) == 500)
        #expect(baseline.sizeDelta(for: renamed) == 0)
    }

    @Test func testRenamedDirectoryDiffsAgainstItsOldEntry() throws {
        let identity = FileIdentity(device: 7, inode: 99)
        let child = makeTestFileNode(id: "/base/old-dir/movie.mov", name: "movie.mov", size: 300)
        let oldDir = makeTestDirectoryNode(
            id: "/base/old-dir", name: "old-dir", children: [child], fileIdentity: identity
        )
        let root = makeTestDirectoryNode(id: "/base", name: "base", children: [oldDir])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [oldDir], oldDir.id: [child]]
        )
        let snapshot = makeTestSnapshot(target: makeTestTarget("/base"), root: root, store: store)
        let baseline = ScanSizeBaseline(snapshot: snapshot)

        let renamedChild = makeTestFileNode(id: "/base/new-dir/movie.mov", name: "movie.mov", size: 300)
        let renamedDir = makeTestDirectoryNode(
            id: "/base/new-dir", name: "new-dir", children: [renamedChild], fileIdentity: identity
        )
        #expect(baseline.movedSourceSize(for: renamedDir) == 300)
        #expect(baseline.sizeDelta(for: renamedDir) == 0)
    }

    @Test func testMovedNodeWithDifferentSizeIsNotARename() throws {
        let identity = FileIdentity(device: 7, inode: 42)
        let oldFile = makeTestFileNode(
            id: "/base/old.bin", name: "old.bin", size: 500, fileIdentity: identity
        )
        let baseline = makeBaseline(children: [oldFile])

        // The size changed too: the hashed pipeline demands an exact size
        // match (its collision guard), so this counts as brand new.
        let movedAndGrown = makeTestFileNode(
            id: "/base/moved.bin", name: "moved.bin", size: 600, fileIdentity: identity
        )
        #expect(baseline.movedSourceSize(for: movedAndGrown) == nil)
        #expect(baseline.sizeDelta(for: movedAndGrown) == 600)
    }

    @Test func testPathMatchWinsOverIdentityMatch() throws {
        let identity = FileIdentity(device: 7, inode: 42)
        let oldFile = makeTestFileNode(
            id: "/base/report.pdf", name: "report.pdf", size: 100, fileIdentity: identity
        )
        let baseline = makeBaseline(children: [oldFile])

        // Same path still exists: diff against it even when an identity
        // also matches (atomic saves migrate inodes without moving files).
        let samePath = makeTestFileNode(
            id: "/base/report.pdf", name: "report.pdf", size: 100, fileIdentity: identity
        )
        #expect(baseline.movedSourceSize(for: samePath) == nil)
        #expect(baseline.sizeDelta(for: samePath) == 0)
    }

    @Test func testHardLinkedNodesNeverMatchAsRenames() throws {
        let identity = FileIdentity(device: 7, inode: 42)
        let oldFile = makeTestFileNode(
            id: "/base/link-a", name: "link-a", size: 500, fileIdentity: identity, linkCount: 2
        )
        let baseline = makeBaseline(children: [oldFile])

        let otherLink = makeTestFileNode(
            id: "/base/link-b", name: "link-b", size: 500, fileIdentity: identity, linkCount: 2
        )
        #expect(baseline.movedSourceSize(for: otherLink) == nil)
        #expect(baseline.sizeDelta(for: otherLink) == 500)
    }

    private func makeBaseline(children: [FileNodeRecord]) -> ScanSizeBaseline {
        let root = makeTestDirectoryNode(id: "/base", name: "base", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let snapshot = makeTestSnapshot(target: makeTestTarget("/base"), root: root, store: store)
        return ScanSizeBaseline(snapshot: snapshot)
    }
}
