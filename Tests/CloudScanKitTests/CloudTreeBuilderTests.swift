import Testing
import Foundation
import NeodiskKit
@testable import CloudScanKit

private let target = CloudTargetID.target(
    providerID: "fixture",
    accountID: "demo",
    displayName: "Fixture Drive"
)!

private func makeBuilder() -> CloudTreeBuilder {
    CloudTreeBuilder(target: target, providerID: "fixture", rootFolderID: "root")
}

private func nodeID(_ fileID: String) -> String {
    CloudTargetID.nodeID(targetID: target.id, fileID: fileID)
}

@Suite struct CloudTargetIDTests {
    @Test func testRoundTrip() {
        let id = CloudTargetID.targetID(providerID: "google", accountID: "12345")
        #expect(id == "cloudscan://google/12345")
        #expect(CloudTargetID.isCloudTargetID(id))
        let parsed = CloudTargetID.parse(id)
        #expect(parsed?.providerID == "google")
        #expect(parsed?.accountID == "12345")
        #expect(!CloudTargetID.isCloudTargetID("/Users/demo"))
        #expect(CloudTargetID.parse("/Users/demo") == nil)
    }

    @Test func testTargetConstruction() {
        #expect(target.kind == .cloud)
        #expect(target.id == "cloudscan://fixture/demo")
        #expect(target.url.absoluteString == target.id)
        #expect(target.displayName == "Fixture Drive")
    }

    @Test func testFileIdentityRoundTrip() {
        let identity = CloudTargetID.identity(providerID: "google", fileID: "abc123")
        #expect(CloudTargetID.fileID(fromIdentity: identity, providerID: "google") == "abc123")
        #expect(CloudTargetID.fileID(fromIdentity: identity, providerID: "dropbox") == nil)
        #expect(CloudTargetID.fileID(fromIdentity: nil, providerID: "google") == nil)
    }
}

@Suite struct CloudTreeBuilderTests {
    @Test func testParentLinkageRollup() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "docs", name: "Docs", parentID: "root", isFolder: true),
            CloudFileEntry(id: "a", name: "a.pdf", parentID: "docs", isFolder: false, logicalBytes: 100, quotaBytes: 100),
            CloudFileEntry(id: "b", name: "b.pdf", parentID: "docs", isFolder: false, logicalBytes: 200, quotaBytes: 200),
            CloudFileEntry(id: "c", name: "c.bin", parentID: "root", isFolder: false, logicalBytes: 50, quotaBytes: 50)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)

        #expect(tree.root.id == target.id)
        #expect(tree.root.allocatedSize == 350)
        #expect(tree.root.descendantFileCount == 3)

        let docs = tree.node(id: nodeID("docs"))
        #expect(docs?.allocatedSize == 300)
        #expect(docs?.isDirectory == true)
        #expect(docs?.descendantFileCount == 2)
        #expect(docs?.path == "\(target.id)/Docs")

        let a = tree.node(id: nodeID("a"))
        #expect(a?.path == "\(target.id)/Docs/a.pdf")
        #expect(a?.pathExtension == "pdf")
        #expect(CloudTargetID.fileID(fromIdentity: a?.fileIdentity, providerID: "fixture") == "a")
    }

    @Test func testQuotaBytesDriveAllocatedAndLogicalKept() {
        var builder = makeBuilder()
        builder.add([
            // Google-native doc: no quota usage, has logical size.
            CloudFileEntry(id: "doc", name: "Doc", parentID: "root", isFolder: false, logicalBytes: 999, quotaBytes: 0),
            // Regular binary.
            CloudFileEntry(id: "bin", name: "x.bin", parentID: "root", isFolder: false, logicalBytes: 10, quotaBytes: 10)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        let doc = tree.node(id: nodeID("doc"))
        #expect(doc?.allocatedSize == 0)
        #expect(doc?.logicalSize == 999)
        #expect(tree.root.allocatedSize == 10)
    }

    @Test func testPathComponentsLinkageSynthesizesFolders() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "p1", name: "deep.txt", pathComponents: ["Photos", "2026", "deep.txt"], isFolder: false, logicalBytes: 7, quotaBytes: 7),
            CloudFileEntry(id: "p2", name: "top.txt", pathComponents: ["top.txt"], isFolder: false, logicalBytes: 3, quotaBytes: 3)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        #expect(tree.root.allocatedSize == 10)
        let deep = tree.node(id: nodeID("p1"))
        #expect(deep?.path == "\(target.id)/Photos/2026/deep.txt")
        // Synthesized intermediates roll up.
        let photos = tree.node(id: nodeID("#path:Photos"))
        #expect(photos?.isDirectory == true)
        #expect(photos?.allocatedSize == 7)
    }

    @Test func testPathLinkagePrefersExplicitFolderEntry() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "folder-id", name: "Photos", pathComponents: ["Photos"], isFolder: true, modifiedAt: Date(timeIntervalSince1970: 1000)),
            CloudFileEntry(id: "p1", name: "a.jpg", pathComponents: ["Photos", "a.jpg"], isFolder: false, logicalBytes: 5, quotaBytes: 5)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        let photos = tree.node(id: nodeID("folder-id"))
        #expect(photos?.allocatedSize == 5)
        #expect(tree.node(id: nodeID("#path:Photos")) == nil)
    }

    @Test func testSiblingNameCollisionDisambiguated() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "x1", name: "report.pdf", parentID: "root", isFolder: false, quotaBytes: 1),
            CloudFileEntry(id: "x2", name: "report.pdf", parentID: "root", isFolder: false, quotaBytes: 2)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        let first = tree.node(id: nodeID("x1"))
        let second = tree.node(id: nodeID("x2"))
        #expect(first?.path != second?.path)
        // Both keep their extension for kind classification.
        #expect(first?.pathExtension == "pdf")
        #expect(second?.pathExtension == "pdf")
        #expect(second?.name.contains("[x2]") == true)
    }

    @Test func testOrphansBucketUnderSharedAndOrphaned() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "ok", name: "ok.txt", parentID: "root", isFolder: false, quotaBytes: 1),
            // Parent never appears in the listing (shared-with-me).
            CloudFileEntry(id: "lost", name: "lost.txt", parentID: "elsewhere", isFolder: false, logicalBytes: 9),
            // No parent at all.
            CloudFileEntry(id: "floating", name: "floating.txt", isFolder: false, logicalBytes: 4)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        let bucketID = nodeID(CloudTreeBuilder.sharedOrphanedFileID)
        let bucket = tree.node(id: bucketID)
        #expect(bucket?.isSynthetic == true)
        #expect(bucket?.isDirectory == true)
        #expect(tree.children(of: bucketID).count == 2)
        #expect(tree.node(id: nodeID("lost")) != nil)
        #expect(tree.node(id: nodeID("floating")) != nil)
    }

    @Test func testParentCycleDoesNotHang() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "a", name: "A", parentID: "b", isFolder: true),
            CloudFileEntry(id: "b", name: "B", parentID: "a", isFolder: true),
            CloudFileEntry(id: "inside", name: "f.txt", parentID: "a", isFolder: false, quotaBytes: 6)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        // Everything still lands somewhere and totals stay sane.
        #expect(tree.node(id: nodeID("inside")) != nil)
        #expect(tree.root.allocatedSize == 6)
    }

    @Test func testUnattributedNodeOnCompleteBuilds() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "f", name: "f.bin", parentID: "root", isFolder: false, quotaBytes: 400)
        ])
        let quota = CloudQuota(totalBytes: 10_000, usedBytes: 1000)

        let complete = builder.buildTree(isComplete: true, quota: quota)
        let unattributedID = nodeID(CloudTreeBuilder.unattributedFileID)
        let unattributed = complete.node(id: unattributedID)
        #expect(unattributed?.isSynthetic == true)
        #expect(unattributed?.allocatedSize == 600)
        #expect(complete.root.allocatedSize == 1000)

        let partial = builder.buildTree(isComplete: false, quota: nil)
        #expect(partial.node(id: unattributedID) == nil)

        // Nothing unattributed when the tree accounts for all quota usage.
        let covered = builder.buildTree(
            isComplete: true,
            quota: CloudQuota(totalBytes: 10_000, usedBytes: 400)
        )
        #expect(covered.node(id: unattributedID) == nil)
    }

    @Test func testDuplicateEntriesAcrossPagesLastWriteWins() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "m", name: "moved.txt", parentID: "root", isFolder: false, quotaBytes: 5),
            CloudFileEntry(id: "dir", name: "Dir", parentID: "root", isFolder: true)
        ])
        // Same file re-listed on a later page after a move.
        builder.add([
            CloudFileEntry(id: "m", name: "moved.txt", parentID: "dir", isFolder: false, quotaBytes: 5)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        #expect(tree.root.allocatedSize == 5)
        #expect(tree.node(id: nodeID("m"))?.path == "\(target.id)/Dir/moved.txt")
        #expect(builder.fileCount == 1)
    }

    @Test func testSlashInNameSanitized() {
        var builder = makeBuilder()
        builder.add([
            CloudFileEntry(id: "s", name: "a/b.txt", parentID: "root", isFolder: false, quotaBytes: 1)
        ])
        let tree = builder.buildTree(isComplete: true, quota: nil)
        #expect(tree.node(id: nodeID("s"))?.name == "a:b.txt")
    }
}
