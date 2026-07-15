//
//  CloneDeduplicatorTests.swift
//  Neodisk
//
//  APFS clone deduplication: one clone family counts its shared blocks
//  once — the path-first member keeps full size, later members are charged
//  only their private (unshared) bytes — plus the end-to-end path over real
//  clonefile(2) copies, and the offline rebalance that survives subtree
//  removals.
//

import Testing
import Foundation
@testable import NeodiskKit

@Suite struct CloneDeduplicatorTests {
    private func makeFile(
        id: String,
        allocatedSize: Int64,
        cloneInfo: CloneInfo? = nil,
        identity: FileIdentity? = nil,
        linkCount: UInt64 = 1
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id),
            name: URL(filePath: id).lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: identity,
            linkCount: linkCount,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false,
            cloneInfo: cloneInfo
        )
    }

    private func makeRoot(id: String, children: [FileNodeRecord]) -> FileNodeRecord {
        FileNodeRecord.directory(
            id: id,
            url: URL(filePath: id, directoryHint: .isDirectory),
            name: URL(filePath: id).lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
    }

    private func store(root: FileNodeRecord, children: [FileNodeRecord]) -> FileTreeStore {
        let storage = TreeStorage.build(
            rootID: root.id,
            nodesByID: children.reduce(into: [root.id: root]) { $0[$1.id] = $1 },
            childIDsByID: [root.id: children.map(\.id)]
        )
        return FileTreeStore(trustedStorage: storage, rootID: root.id)
    }

    private func applyDeduplication(
        to store: FileTreeStore,
        privateSizeProvider: @escaping (String) -> Int64?
    ) -> FileTreeStore {
        let storage = store.storage
        var nodes = storage.nodes
        var childSlots = storage.childSlots
        CloneDeduplicator.applyDeduplication(
            nodes: &nodes,
            parentIndices: storage.parentIndices,
            childStarts: storage.childStarts,
            childSlots: &childSlots,
            indexByID: storage.indexByID,
            privateSizeProvider: privateSizeProvider
        )
        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: storage.parentIndices,
                childStarts: storage.childStarts,
                childSlots: childSlots,
                indexByID: storage.indexByID
            ),
            rootID: store.rootID
        )
    }

    @Test func testFamilyCountsSharedBlocksOnce() {
        let family = CloneInfo(device: 1, cloneID: 42, refCount: 3)
        let children = [
            makeFile(id: "/r/a.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/b.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/c.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/plain.bin", allocatedSize: 7),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )

        // Path-first member keeps the shared 100; the two later members are
        // charged their (zero) private bytes.
        #expect(deduped.node(id: "/r/a.bin")?.allocatedSize == 100)
        #expect(deduped.node(id: "/r/b.bin")?.allocatedSize == 0)
        #expect(deduped.node(id: "/r/c.bin")?.allocatedSize == 0)
        #expect(deduped.node(id: "/r/plain.bin")?.allocatedSize == 7)
        #expect(deduped.root.allocatedSize == 107)
        // Fetched private sizes are stamped for offline rebalances.
        #expect(deduped.node(id: "/r/b.bin")?.cloneInfo?.privateSize == 0)
    }

    @Test func testDivergedMemberKeepsItsPrivateBytes() {
        let family = CloneInfo(device: 1, cloneID: 7, refCount: 2)
        let children = [
            makeFile(id: "/r/original.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/tweaked.bin", allocatedSize: 100, cloneInfo: family),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { path in path.hasSuffix("tweaked.bin") ? 30 : 0 }
        )

        #expect(deduped.node(id: "/r/original.bin")?.allocatedSize == 100)
        #expect(deduped.node(id: "/r/tweaked.bin")?.allocatedSize == 30)
        #expect(deduped.root.allocatedSize == 130)
    }

    @Test func testDistinctFamiliesAndDevicesStayIndependent() {
        let familyA = CloneInfo(device: 1, cloneID: 7, refCount: 2)
        let sameIDOtherDevice = CloneInfo(device: 2, cloneID: 7, refCount: 2)
        let children = [
            makeFile(id: "/r/a1.bin", allocatedSize: 50, cloneInfo: familyA),
            makeFile(id: "/r/a2.bin", allocatedSize: 50, cloneInfo: familyA),
            makeFile(id: "/r/other-volume.bin", allocatedSize: 50, cloneInfo: sameIDOtherDevice),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )

        // The other-device file is that family's only scanned member.
        #expect(deduped.node(id: "/r/other-volume.bin")?.allocatedSize == 50)
        #expect(deduped.root.allocatedSize == 100)
    }

    @Test func testUnknownPrivateSizeChargesZero() {
        let family = CloneInfo(device: 1, cloneID: 9, refCount: 2)
        let children = [
            makeFile(id: "/r/a.bin", allocatedSize: 80, cloneInfo: family),
            makeFile(id: "/r/b.bin", allocatedSize: 80, cloneInfo: family),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in nil }
        )

        // Conservative: the residual surfaces as hidden space, never as an
        // over-count.
        #expect(deduped.node(id: "/r/b.bin")?.allocatedSize == 0)
        #expect(deduped.root.allocatedSize == 80)
    }

    @Test func testRebalancePromotesSurvivorAfterRemoval() throws {
        let family = CloneInfo(device: 1, cloneID: 3, refCount: 2)
        let children = [
            makeFile(id: "/r/a.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/b.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/plain.bin", allocatedSize: 5),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )
        #expect(deduped.root.allocatedSize == 105)

        // Deleting the kept member must hand the family's full size to the
        // charged survivor, offline (stamped private sizes only).
        let survivors = [
            try #require(deduped.node(id: "/r/b.bin")),
            try #require(deduped.node(id: "/r/plain.bin")),
        ]
        let spliced = store(root: makeRoot(id: "/r", children: survivors), children: survivors)
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(spliced)

        #expect(rebalanced.node(id: "/r/b.bin")?.allocatedSize == 100)
        #expect(rebalanced.root.allocatedSize == 105)
    }

    @Test func testHardLinkManagedNodesAreLeftToTheHardLinkPass() throws {
        // A node that is both hard-linked and clone-stamped: the hard-link
        // rebalance owns its size; the clone pass must not restore it.
        let family = CloneInfo(device: 1, cloneID: 5, refCount: 2, privateSize: 0)
        let identity = FileIdentity.fileSystem(device: 1, inode: 99)
        let children = [
            makeFile(id: "/r/link-a.bin", allocatedSize: 60, cloneInfo: family, identity: identity, linkCount: 2),
            makeFile(id: "/r/link-b.bin", allocatedSize: 60, cloneInfo: family, identity: identity, linkCount: 2),
        ]
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(
            store(root: makeRoot(id: "/r", children: children), children: children)
        )

        // Hard-link dedup keeps one 60; clone pass charges the duplicate's
        // stamped private size without double-restoring the first member.
        #expect(rebalanced.root.allocatedSize == 60)
    }

    @Test func testEndToEndScanCountsClonedFileOnce() async throws {
        let fileManager = FileManager.default
        let rootURL = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "clone-dedup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let payloadSize = 256 * 1024
        let originalURL = rootURL.appending(path: "original.bin")
        let cloneURL = rootURL.appending(path: "zz-clone.bin")
        try Data(repeating: 0xA5, count: payloadSize).write(to: originalURL)
        let cloned = originalURL.withUnsafeFileSystemRepresentation { source in
            cloneURL.withUnsafeFileSystemRepresentation { destination in
                clonefile(source!, destination!, 0)
            }
        }
        // Non-APFS temp locations can't clone; nothing to verify there.
        try #require(cloned == 0, "clonefile failed (errno \(errno)) — is the temp dir APFS?")

        let engine = ScanEngine()
        var finalSnapshot: ScanSnapshot?
        for try await event in engine.scan(target: ScanTarget(url: rootURL, kind: .folder), options: ScanOptions()) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }
        let snapshot = try #require(finalSnapshot)

        let original = try #require(snapshot.treeStore.node(id: originalURL.path))
        let clone = try #require(snapshot.treeStore.node(id: cloneURL.path))
        #expect(original.cloneInfo != nil)
        #expect(clone.cloneInfo != nil)
        #expect(original.cloneInfo?.familyKey == clone.cloneInfo?.familyKey)
        // The family's shared blocks count once: the pair's total is the
        // payload, not double it.
        #expect(original.allocatedSize + clone.allocatedSize >= Int64(payloadSize))
        #expect(original.allocatedSize + clone.allocatedSize < Int64(payloadSize) * 2)
    }
}
