import Foundation
import Testing
@testable import NeodiskKit

@Suite struct NodeIDIndexTests {
    @Test func testLookupWithPrecomputedHashMatchesSubscript() {
        var index = NodeIDIndex()
        index["/a/one"] = 1
        index["/a/two"] = 2
        index["/a/three"] = 3

        for id in ["/a/one", "/a/two", "/a/three"] {
            #expect(index.lookup(hash: FNV1a.hash(id), id: id) == index[id])
        }
        // An absent ID (with its real hash) misses.
        #expect(index.lookup(hash: FNV1a.hash("/a/missing"), id: "/a/missing") == nil)
    }

    @Test func testForcedHashCollisionStillDiscriminatesByString() {
        // Two different IDs forced into the same bucket under one hash: if
        // lookup keyed on the hash alone it would confuse them. String
        // equality inside HashedKey must keep them apart.
        var index = NodeIDIndex()
        let collidingHash: UInt64 = 0xABCD_EF01_2345_6789
        index.updateValue(11, forKey: "/collision/first", hash: collidingHash)
        index.updateValue(22, forKey: "/collision/second", hash: collidingHash)

        #expect(index.lookup(hash: collidingHash, id: "/collision/first") == 11)
        #expect(index.lookup(hash: collidingHash, id: "/collision/second") == 22)
        // A third string sharing the hash but never inserted still misses.
        #expect(index.lookup(hash: collidingHash, id: "/collision/third") == nil)
    }

    @Test func testBuildingReturnsHashesAlignedToNodeOrder() throws {
        let nodes = [
            makeTestDirectoryNode(id: "/root", name: "root", children: []),
            makeTestFileNode(id: "/root/a.txt", name: "a.txt", size: 1),
            makeTestFileNode(id: "/root/b.txt", name: "b.txt", size: 2)
        ]
        let built = try #require(NodeIDIndex.building(from: nodes))

        #expect(built.hashes.count == nodes.count)
        for (offset, node) in nodes.enumerated() {
            #expect(built.hashes[offset] == FNV1a.hash(node.id))
            // The returned index resolves each node, and lookup by the stored
            // hash agrees with the plain subscript.
            #expect(built.index.lookup(hash: built.hashes[offset], id: node.id) == Int32(offset))
        }
    }

    @Test func testGrowingPastInitialCapacityKeepsEveryKey() {
        var index = NodeIDIndex()
        let ids = (0..<5_000).map { "/grow/\($0)" }
        for (value, id) in ids.enumerated() {
            #expect(index.updateValue(Int32(value), forKey: id) == nil)
        }
        for (value, id) in ids.enumerated() {
            #expect(index[id] == Int32(value))
        }
        #expect(index["/grow/missing"] == nil)
    }

    @Test func testInsertIfAbsentKeepsTheFirstOccurrence() {
        var index = NodeIDIndex()
        #expect(index.insertIfAbsent(0, forKey: "/dup") == nil)
        #expect(index.insertIfAbsent(1, forKey: "/dup") == 0)
        #expect(index["/dup"] == 0)
    }

    @Test func testAttachedIndexReadsKeysFromTheNodes() throws {
        let nodes = [
            makeTestDirectoryNode(id: "/root", name: "root", children: []),
            makeTestFileNode(id: "/root/a.txt", name: "a.txt", size: 1),
        ]
        var index = NodeIDIndex()
        index["/root"] = 0
        index["/root/a.txt"] = 1
        let attached = index.attached(to: nodes)
        #expect(attached["/root/a.txt"] == 1)
        #expect(attached["/root"] == 0)
        // Editing an attached index detaches it without losing keys.
        var edited = attached
        edited["/root/b.txt"] = 2
        #expect(edited["/root/a.txt"] == 1)
        #expect(edited["/root/b.txt"] == 2)
    }

    @Test func testBuildingRejectsDuplicateIDs() {
        let nodes = [
            makeTestFileNode(id: "/same", name: "same", size: 1),
            makeTestFileNode(id: "/same", name: "same", size: 2),
        ]
        #expect(NodeIDIndex.building(from: nodes) == nil)
    }
}
