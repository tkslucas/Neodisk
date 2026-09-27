import Foundation
import Testing
@testable import NeodiskKit

/// Sibling display order lives in a store's child slots; the in-place
/// ancestor rebuild (shared-size dedup, splices) re-sorts those slots without
/// moving node records. The codec and the content digest must follow the
/// slots, and decoding a file written by the old array-order encoder must
/// restore display order.
@Suite struct SnapshotChildOrderTests {
    /// /r
    /// ├── Alpha/  big.bin (hard link, 400) · small.bin (40)
    /// └── Beta/   big.bin (hard link, 400) · small.bin (40)
    ///
    /// Dedup charges Beta/big.bin zero (Alpha's link sorts first), so Beta's
    /// display order flips to [small.bin, big.bin] while its records stay in
    /// the pre-dedup array order.
    private func makeDedupReorderedStore() throws -> FileTreeStore {
        let identity = FileIdentity.fileSystem(device: 1, inode: 42)
        var childrenByID: [String: [FileNodeRecord]] = [:]
        var directories: [FileNodeRecord] = []
        for name in ["Alpha", "Beta"] {
            let dirID = "/r/\(name)"
            let big = makeTestFileNode(
                id: "\(dirID)/big.bin", name: "big.bin", size: 400,
                fileIdentity: identity, linkCount: 2
            )
            let small = makeTestFileNode(id: "\(dirID)/small.bin", name: "small.bin", size: 40)
            childrenByID[dirID] = [big, small]
            directories.append(makeTestDirectoryNode(id: dirID, name: name, children: [big, small]))
        }
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: directories)
        childrenByID[root.id] = directories
        return try SharedSizeDeduplication.rebalancedStore(
            FileTreeStore(root: root, childrenByID: childrenByID)
        )
    }

    private func snapshot(of store: FileTreeStore) -> ScanSnapshot {
        makeTestSnapshot(
            target: makeTestTarget(store.rootID),
            root: store.root,
            store: store,
            startedAt: Date(timeIntervalSince1970: 1_705_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_705_000_100)
        )
    }

    private func childOrders(_ store: FileTreeStore) -> [String: [String]] {
        var orders: [String: [String]] = [:]
        for node in store.allNodes where node.isDirectory {
            orders[node.id] = store.children(of: node.id).map { "\($0.name)=\($0.allocatedSize)" }
        }
        return orders
    }

    @Test func dedupReorderedSiblingsSurviveCodecRoundTrip() throws {
        let live = try makeDedupReorderedStore()
        // Precondition: the fixture really exercises the lag — Beta's records
        // sit in pre-dedup order while its slots were re-sorted.
        #expect(live.children(of: "/r/Beta").map(\.name) == ["small.bin", "big.bin"])
        let betaIndex = try #require(live.storage.index(of: "/r/Beta"))
        let arrayOrder = live.storage.nodes.indices
            .filter { live.storage.parentIndices[$0] == betaIndex }
            .map { live.storage.nodes[$0].name }
        #expect(arrayOrder == ["big.bin", "small.bin"])

        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(snapshot(of: live)))

        #expect(childOrders(decoded.treeStore) == childOrders(live))
    }

    @Test func contentDigestFollowsDisplayOrderNotArrayOrder() throws {
        let live = try makeDedupReorderedStore()
        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(snapshot(of: live)))

        // Same content, different record-array order: equal digests, so an
        // unchanged rescan never rotates the previous baseline away.
        #expect(ScanChangeList.contentDigest(of: decoded.treeStore) == ScanChangeList.contentDigest(of: live))
    }

    @Test func decodeRestoresDisplayOrderFromArrayOrderFiles() throws {
        // A file the old array-order encoder wrote: stream order puts the
        // small child first. The validating init keeps the caller's child
        // order, so encoding this store reproduces that stream exactly.
        let small = makeTestFileNode(id: "/r/a.bin", name: "a.bin", size: 5)
        let big = makeTestFileNode(id: "/r/b.bin", name: "b.bin", size: 50)
        let tieLate = makeTestFileNode(id: "/r/z.bin", name: "z.bin", size: 5)
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [small, big, tieLate])
        let stale = FileTreeStore(
            rootID: root.id,
            nodesByID: [root.id: root, small.id: small, big.id: big, tieLate.id: tieLate],
            childIDsByID: [root.id: [tieLate.id, small.id, big.id]],
            parentIDByID: [small.id: root.id, big.id: root.id, tieLate.id: root.id]
        )
        #expect(stale.children(of: root.id).map(\.name) == ["z.bin", "a.bin", "b.bin"])

        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(snapshot(of: stale)))

        #expect(decoded.treeStore.children(of: root.id).map(\.name) == ["b.bin", "a.bin", "z.bin"])
    }

    @Test func restoreLeavesOrderedRangesUntouched() throws {
        let storage = try makeDedupReorderedStore().storage
        var childSlots = storage.childSlots
        let repaired = TreeStorage.restoreChildDisplayOrder(
            nodes: storage.nodes,
            childStarts: storage.childStarts,
            childSlots: &childSlots
        )
        #expect(repaired == 0)
        #expect(childSlots == storage.childSlots)
    }

    @Test func restoreSkipsRangesOrderedBySize() {
        // Equal sizes in non-name order: detection is size-only by design
        // (no string work per decode), so the range is left as is.
        let z = makeTestFileNode(id: "/r/z.bin", name: "z.bin", size: 5)
        let a = makeTestFileNode(id: "/r/a.bin", name: "a.bin", size: 5)
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: [z, a])
        let nodes = [root, z, a]
        var childSlots: [Int32] = [1, 2]
        let repaired = TreeStorage.restoreChildDisplayOrder(
            nodes: nodes,
            childStarts: [0, 2, 2, 2],
            childSlots: &childSlots
        )
        #expect(repaired == 0)
        #expect(childSlots == [1, 2])
    }

    /// End to end on a real volume: a hard-link pair and an APFS clone pair
    /// across two folders, scanned, encoded, and decoded.
    @Test func scannedSharedSizeTreeSurvivesCodecRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for dir in ["Alpha", "Beta"] {
            let url = root.appending(path: dir, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 40_000).write(to: url.appending(path: "small.bin"))
        }
        let linked = root.appending(path: "Alpha/linked.bin")
        try Data(repeating: 2, count: 400_000).write(to: linked)
        try FileManager.default.linkItem(at: linked, to: root.appending(path: "Beta/linked.bin"))
        // copyItem clones on APFS; elsewhere it is a plain copy and the
        // round trip must hold all the same.
        let cloned = root.appending(path: "Alpha/cloned.bin")
        try Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: cloned)
        try FileManager.default.copyItem(at: cloned, to: root.appending(path: "Beta/cloned.bin"))

        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let live = try #require(finished)
        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(live))

        #expect(childOrders(decoded.treeStore) == childOrders(live.treeStore))
        #expect(ScanChangeList.contentDigest(of: decoded.treeStore) == ScanChangeList.contentDigest(of: live.treeStore))
    }
}
