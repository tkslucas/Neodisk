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
        privateSizeProvider: @escaping @Sendable (String) -> Int64?,
        progress: (Double) -> Void = { _ in }
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
            privateSizeProvider: privateSizeProvider,
            cancellationCheck: {},
            progress: progress
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

    @Test func testProgressReportsFetchBatchesUpToOne() {
        let family = CloneInfo(device: 1, cloneID: 9, refCount: 3)
        let children = [
            makeFile(id: "/r/a.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/b.bin", allocatedSize: 100, cloneInfo: family),
            makeFile(id: "/r/c.bin", allocatedSize: 100, cloneInfo: family),
        ]
        var fractions: [Double] = []
        _ = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 },
            progress: { fractions.append($0) }
        )

        #expect(!fractions.isEmpty)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(fractions.last == 1)
    }

    @Test func testProgressSilentWithoutChargedMembers() {
        let children = [makeFile(id: "/r/plain.bin", allocatedSize: 7)]
        var fractions: [Double] = []
        _ = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 },
            progress: { fractions.append($0) }
        )
        #expect(fractions.isEmpty)
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

    private func makePackage(id: String, allocatedSize: Int64, families: [SummarizedCloneFamily]) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(filePath: id, directoryHint: .isDirectory),
            name: URL(filePath: id).lastPathComponent,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: true,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false,
            summarizedClones: SummarizedClones(families: families)
        )
    }

    private func tally(_ cloneID: UInt64, members: UInt32 = 1, size: Int64 = 100) -> SummarizedCloneFamily {
        SummarizedCloneFamily(
            familyKey: CloneFamilyKey(device: 1, cloneID: cloneID),
            memberCount: members,
            totalSize: size * Int64(members),
            largestSize: size
        )
    }

    @Test func testClonedPackagesCountSharedBlocksOnce() {
        // Cloned copies of an app: each package holds one member of the
        // family; only the path-first package keeps it.
        let children = [
            makePackage(id: "/r/A.app", allocatedSize: 130, families: [tally(7)]),
            makePackage(id: "/r/B.app", allocatedSize: 130, families: [tally(7)]),
            makePackage(id: "/r/C.app", allocatedSize: 130, families: [tally(7)]),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )

        #expect(deduped.node(id: "/r/A.app")?.allocatedSize == 130)
        #expect(deduped.node(id: "/r/B.app")?.allocatedSize == 30)
        #expect(deduped.node(id: "/r/C.app")?.allocatedSize == 30)
        #expect(deduped.root.allocatedSize == 190)
        #expect(deduped.node(id: "/r/B.app")?.summarizedClones?.families.first?.charge == 100)
    }

    @Test func testClonesInsideOnePackageCountOnce() {
        let children = [makePackage(id: "/r/A.app", allocatedSize: 320, families: [tally(8, members: 3)])]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )

        #expect(deduped.node(id: "/r/A.app")?.allocatedSize == 120)
    }

    @Test func testPackagesAndFilesShareOneFamily() {
        let family = CloneInfo(device: 1, cloneID: 9, refCount: 3, privateSize: 0)
        let children = [
            makeFile(id: "/r/a.bin", allocatedSize: 100, cloneInfo: family),
            makePackage(id: "/r/m.app", allocatedSize: 100, families: [tally(9)]),
            makeFile(id: "/r/z.bin", allocatedSize: 100, cloneInfo: family),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )

        #expect(deduped.node(id: "/r/a.bin")?.allocatedSize == 100)
        #expect(deduped.node(id: "/r/m.app")?.allocatedSize == 0)
        #expect(deduped.node(id: "/r/z.bin")?.allocatedSize == 0)
        #expect(deduped.root.allocatedSize == 100)
    }

    @Test func testPackageMembersSortBelowThePackagePath() {
        // "/r/a/…" (inside the package) sorts after "/r/a-x.bin": "-" < "/".
        let family = CloneInfo(device: 1, cloneID: 10, refCount: 2, privateSize: 0)
        let children = [
            makePackage(id: "/r/a", allocatedSize: 100, families: [tally(10)]),
            makeFile(id: "/r/a-x.bin", allocatedSize: 100, cloneInfo: family),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )

        #expect(deduped.node(id: "/r/a-x.bin")?.allocatedSize == 100)
        #expect(deduped.node(id: "/r/a")?.allocatedSize == 0)
    }

    @Test func testRebalanceHandsAPackageTheFamilyAfterRemoval() throws {
        let children = [
            makePackage(id: "/r/A.app", allocatedSize: 130, families: [tally(11)]),
            makePackage(id: "/r/B.app", allocatedSize: 130, families: [tally(11)]),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )
        #expect(deduped.root.allocatedSize == 160)

        // Deleting the package that kept the family hands it to the survivor.
        let survivors = [try #require(deduped.node(id: "/r/B.app"))]
        let spliced = store(root: makeRoot(id: "/r", children: survivors), children: survivors)
        var scope = SharedSizeDeduplication.Scope()
        scope.include(try #require(deduped.node(id: "/r/A.app")))
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(spliced, scope: scope)

        #expect(rebalanced.node(id: "/r/B.app")?.allocatedSize == 130)
        #expect(rebalanced.node(id: "/r/B.app")?.summarizedClones?.families.first?.charge == 0)
        #expect(rebalanced.root.allocatedSize == 130)
    }

    @Test func testRebalanceChargesAnInsertedPackage() throws {
        // A new cloned copy arriving in a rescan carries no charge yet.
        let kept = makePackage(id: "/r/A.app", allocatedSize: 130, families: [tally(12)])
        let inserted = makePackage(id: "/r/B.app", allocatedSize: 130, families: [tally(12)])
        var scope = SharedSizeDeduplication.Scope()
        scope.include(inserted)
        let rebalanced = try SharedSizeDeduplication.rebalancedStore(
            store(root: makeRoot(id: "/r", children: [kept, inserted]), children: [kept, inserted]),
            scope: scope
        )

        #expect(rebalanced.node(id: "/r/A.app")?.allocatedSize == 130)
        #expect(rebalanced.node(id: "/r/B.app")?.allocatedSize == 30)
        #expect(rebalanced.root.allocatedSize == 160)
    }

    @Test func testSummarizedClonesSurviveTheSnapshotCodec() throws {
        let children = [
            makePackage(id: "/r/A.app", allocatedSize: 130, families: [tally(13)]),
            makePackage(id: "/r/B.app", allocatedSize: 130, families: [tally(13), tally(14, members: 2)]),
        ]
        let deduped = applyDeduplication(
            to: store(root: makeRoot(id: "/r", children: children), children: children),
            privateSizeProvider: { _ in 0 }
        )
        let snapshot = ScanSnapshot(
            target: ScanTarget(url: URL(filePath: "/r", directoryHint: .isDirectory), kind: .folder),
            treeStore: deduped,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 1),
            scanWarnings: [],
            aggregateStats: deduped.aggregateStats,
            isComplete: true
        )
        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(snapshot))

        let package = try #require(decoded.treeStore.node(id: "/r/B.app"))
        #expect(package.summarizedClones == deduped.node(id: "/r/B.app")?.summarizedClones)
        #expect(package.allocatedSize == deduped.node(id: "/r/B.app")?.allocatedSize)
        // v4 files carry no tallies.
        let v4 = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(snapshot, version: 4))
        #expect(v4.treeStore.node(id: "/r/B.app")?.summarizedClones == nil)
    }

    #if canImport(Darwin)
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
        // Traversal reads every member's private size as it lists the folder,
        // so deduplication never has to go back to the file system.
        #expect(original.cloneInfo?.privateSize != nil)
        #expect(clone.cloneInfo?.privateSize != nil)
        // The family's shared blocks count once: the pair's total is the
        // payload, not double it.
        #expect(original.allocatedSize + clone.allocatedSize >= Int64(payloadSize))
        #expect(original.allocatedSize + clone.allocatedSize < Int64(payloadSize) * 2)
    }
    @Test func testEndToEndScanCountsClonedPackagesOnce() async throws {
        let fileManager = FileManager.default
        let rootURL = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "clone-dedup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: rootURL) }

        // The same app cloned twice (as Finder's Duplicate or a code-signing
        // copy does): packages are summarized, not listed file by file.
        let payloadSize = 256 * 1024
        let originalApp = rootURL.appending(path: "Original.app", directoryHint: .isDirectory)
        let binary = originalApp.appending(path: "Contents/MacOS/binary")
        try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: payloadSize).write(to: binary)
        for copy in ["Copy 1.app", "Copy 2.app"] {
            let destination = rootURL.appending(path: copy, directoryHint: .isDirectory)
            let cloned = originalApp.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { destination in
                    clonefile(source!, destination!, 0)
                }
            }
            try #require(cloned == 0, "clonefile failed (errno \(errno)) — is the temp dir APFS?")
        }

        let engine = ScanEngine()
        var finalSnapshot: ScanSnapshot?
        for try await event in engine.scan(target: ScanTarget(url: rootURL, kind: .folder), options: ScanOptions()) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }
        let snapshot = try #require(finalSnapshot)

        let packages = try ["Copy 1.app", "Copy 2.app", "Original.app"].map { name in
            try #require(snapshot.treeStore.node(id: rootURL.appending(path: name).path))
        }
        #expect(packages.allSatisfy { $0.isPackage })
        // Three copies, one payload's worth of blocks.
        let total = packages.reduce(Int64(0)) { $0 + $1.allocatedSize }
        #expect(total >= Int64(payloadSize))
        #expect(total < Int64(payloadSize) * 2)
    }
    #endif
}
