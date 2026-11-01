import Foundation
import Testing
@testable import NeodiskKit

/// Every stored field of a record: its description has the inline ones (minus a private type's load address), the
/// rest sit in a box the description doesn't open.
func snapshotRecordSignature(_ node: FileNodeRecord) -> String {
    String(describing: node).replacingOccurrences(of: #"\$[0-9a-f]+"#, with: "", options: .regularExpression)
        + "|\(node.path)|\(String(describing: node.fileIdentity))|\(String(describing: node.cloneInfo))"
        + "|\(node.cloudOnlyLogicalSize)|\(String(describing: node.summarizedClones))"
}

/// Decode builds records in batches on worker threads; these trees span several batches.
@Suite struct SnapshotDecodeBatchTests {
    /// Three folders of `filesPerFolder` files under a root, one nested folder each.
    private func makeSnapshot(filesPerFolder: Int) -> ScanSnapshot {
        var childrenByID: [String: [FileNodeRecord]] = [:]
        var folders: [FileNodeRecord] = []
        for folderIndex in 0..<3 {
            let folderID = "/root/folder \(folderIndex)"
            let nestedID = "\(folderID)/nested"
            let nestedFile = makeTestFileNode(id: "\(nestedID)/deep.bin", name: "deep.bin", size: 7)
            childrenByID[nestedID] = [nestedFile]
            var children = [makeTestDirectoryNode(id: nestedID, name: "nested", children: [nestedFile])]
            for fileIndex in 0..<filesPerFolder {
                let name = "file-\(fileIndex)-with-a-name-longer-than-fifteen-bytes.txt"
                children.append(makeTestFileNode(id: "\(folderID)/\(name)", name: name, size: Int64(fileIndex + 1)))
            }
            childrenByID[folderID] = children
            folders.append(makeTestDirectoryNode(id: folderID, name: "folder \(folderIndex)", children: children))
        }
        childrenByID["/root"] = folders
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: folders)
        let store = FileTreeStore(root: root, childrenByID: childrenByID)
        return ScanSnapshot(
            target: makeTestTarget("/root"),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1_705_000_100),
            finishedAt: Date(timeIntervalSince1970: 1_705_000_200),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true
        )
    }

    @Test func testManyBatchesRoundTripExactly() throws {
        let snapshot = makeSnapshot(filesPerFolder: 10_000)
        for version in [UInt32(1), ScanSnapshotCache.currentFormatVersion] {
            let encoded = try ScanSnapshotCodec.encode(snapshot, version: version)
            let decoded = try ScanSnapshotCodec.decode(encoded)
            #expect(decoded.treeStore.nodeCount == snapshot.treeStore.nodeCount)
            let source = snapshot.treeStore.storage
            let storage = decoded.treeStore.storage
            // Every record equal to its source, under the same parent.
            var mismatches = 0
            for (index, node) in source.nodes.enumerated() {
                let parent = source.parentIndices[index]
                guard let decodedIndex = storage.indexByID[node.id],
                      snapshotRecordSignature(storage.nodes[Int(decodedIndex)]) == snapshotRecordSignature(node) else {
                    mismatches += 1
                    continue
                }
                let decodedParent = storage.parentIndices[Int(decodedIndex)]
                let parentID = parent >= 0 ? source.nodes[Int(parent)].id : nil
                if (decodedParent >= 0 ? storage.nodes[Int(decodedParent)].id : nil) != parentID { mismatches += 1 }
            }
            #expect(mismatches == 0)
            #expect(storage.nodeHashes == storage.nodes.map { FNV1a.hash($0.id) })
            let deep = try #require(decoded.treeStore.node(id: "/root/folder 2/nested/deep.bin"))
            #expect(deep.name == "deep.bin" && deep.path == deep.id && deep.allocatedSize == 7)
        }
    }

    /// A failure after workers already built some batches throws and releases them.
    @Test func testTruncationAfterSeveralBatchesThrows() throws {
        let encoded = try ScanSnapshotCodec.encode(makeSnapshot(filesPerFolder: 10_000), version: 1)
        for keptFraction in [0.6, 0.999] {
            let truncated = encoded.prefix(Int(Double(encoded.count) * keptFraction))
            #expect(throws: ScanSnapshotCacheError.self) { try ScanSnapshotCodec.decode(Data(truncated)) }
        }
    }
}
