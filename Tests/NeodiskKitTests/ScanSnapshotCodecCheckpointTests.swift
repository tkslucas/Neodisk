import Foundation
import Testing
@testable import NeodiskKit

/// The incremental FSEvents checkpoint and effective scan options ride in the
/// snapshot's metadata JSON, which is additive: files written before either
/// field existed must still decode (as nil), and new files must round-trip
/// both exactly through every supported format version.
@Suite struct ScanSnapshotCodecCheckpointTests {
    // A checkpoint with deliberately awkward values: a lowercased UUID (the
    // live-volume comparison is case-insensitive, so persistence must not
    // silently normalize it) and a large event ID.
    private static let checkpoint = FSEventsCheckpoint(
        volumeUUID: "abcdef01-2345-6789-abcd-ef0123456789",
        eventID: 9_876_543_210,
        capturedAt: Date(timeIntervalSince1970: 1_705_000_000),
        osBuild: "23G93"
    )

    // Non-default options across the axes that matter for a rescan: a shape
    // change (hidden files, cloud off), an exclusion list, an exclusion root,
    // and tuning overrides.
    private static let options = ScanOptions(
        includeHiddenFiles: true,
        includeCloudStorage: false,
        exclusionPatterns: ["node_modules", "*.tmp", "/Users/x/Library/Caches"],
        exclusionRootPath: "/Users/x/project",
        tuning: ScanOptions.Tuning(
            autoSummarizeMinFileCount: 1234,
            autoSummarizeMaxAverageFileSize: 8192,
            autoSummarizeMinDepthForSummarization: 3,
            atomicSummaryWorkerLimit: 2,
            directoryClassificationWorkerLimit: 5,
            directoryTraversalWorkerLimit: 7
        )
    )

    private func makeSnapshot(
        checkpoint: FSEventsCheckpoint? = ScanSnapshotCodecCheckpointTests.checkpoint,
        options: ScanOptions? = ScanSnapshotCodecCheckpointTests.options,
        source: ScanSnapshotSource = .live
    ) -> ScanSnapshot {
        let file = makeTestFileNode(id: "/root/a.txt", name: "a.txt", size: 100)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        return ScanSnapshot(
            target: makeTestTarget("/root"),
            treeStore: store,
            startedAt: Date(timeIntervalSince1970: 1_705_000_100),
            finishedAt: Date(timeIntervalSince1970: 1_705_000_200),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            scanOptions: options,
            source: source,
            incrementalCheckpoint: checkpoint
        )
    }

    @Test func testCheckpointAndOptionsRoundTrip() throws {
        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(makeSnapshot()))
        #expect(decoded.incrementalCheckpoint == Self.checkpoint)
        // Byte-for-byte, including the lowercased UUID.
        #expect(decoded.incrementalCheckpoint?.volumeUUID == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(decoded.scanOptions == Self.options)
    }

    @Test func testMissingFieldsDecodeAsNil() throws {
        // A writer that never set either field omits both from the metadata
        // JSON (nil optionals are not encoded), so decode must yield nils.
        let decoded = try ScanSnapshotCodec.decode(
            try ScanSnapshotCodec.encode(makeSnapshot(checkpoint: nil, options: nil))
        )
        #expect(decoded.incrementalCheckpoint == nil)
        #expect(decoded.scanOptions == nil)
    }

    @Test func testOlderFileWithoutKeysDecodes() throws {
        // Prove a genuinely older file — metadata JSON physically missing the
        // keys — decodes, even when its payload came from a checkpoint-carrying
        // tree. Encode with the fields, then strip the keys and repair the
        // length header as a pre-field writer's file would have looked.
        let blob = try ScanSnapshotCodec.encode(makeSnapshot())
        let stripped = try strippingMetadataKeys(["incrementalCheckpoint", "scanOptions"], from: blob)

        let decoded = try ScanSnapshotCodec.decode(stripped)
        #expect(decoded.incrementalCheckpoint == nil)
        #expect(decoded.scanOptions == nil)
        #expect(decoded.treeStore.nodeCount == 2)
    }

    @Test func testReadMetadataSurfacesCheckpointHeaderOnly() throws {
        let blob = try ScanSnapshotCodec.encode(makeSnapshot())
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".ndscan")
        try blob.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try ScanSnapshotCodec.readMetadata(fromFileAt: url)
        #expect(metadata.incrementalCheckpoint == Self.checkpoint)
        #expect(metadata.scanOptions == Self.options)
    }

    @Test func testV2FormatRoundTripsNewMetadata() throws {
        // Metadata is version-independent; an explicit v2 file must carry the
        // new fields just as v3 does.
        let blob = try ScanSnapshotCodec.encode(makeSnapshot(), version: 2)
        let decoded = try ScanSnapshotCodec.decode(blob)
        #expect(decoded.incrementalCheckpoint == Self.checkpoint)
        #expect(decoded.scanOptions == Self.options)
    }

    @Test func testNonPersistableSourceNilsCheckpoint() throws {
        // The ScanSnapshot init drops the checkpoint for imported archives, so
        // an import can never persist a stale journal position.
        let imported = ScanSnapshotSource.imported(
            ImportedSnapshotContext(sourceURL: URL(filePath: "/tmp/x.ndscan"),
                                    pathMode: .absolute,
                                    liveActionCapability: .disabled)
        )
        let snapshot = makeSnapshot(source: imported)
        #expect(snapshot.incrementalCheckpoint == nil)
    }

    /// Rebuilds a snapshot blob with the named top-level metadata keys removed
    /// and the length header corrected, mimicking a file from a writer that
    /// predates those keys. Layout: magic(4) · version(4) · metadataLength(4)
    /// · metadata JSON · payload (all little-endian).
    private func strippingMetadataKeys(_ keys: Set<String>, from blob: Data) throws -> Data {
        let metadataLength = Int(blob.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        })
        let metadataStart = 12
        let metadataEnd = metadataStart + metadataLength
        let metadataData = blob.subdata(in: metadataStart..<metadataEnd)
        let payload = blob.subdata(in: metadataEnd..<blob.count)

        var json = try #require(
            try JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        for key in keys { json.removeValue(forKey: key) }
        let newMetadata = try JSONSerialization.data(withJSONObject: json)

        var out = Data()
        out.append(blob.subdata(in: 0..<8)) // magic + version, unchanged
        var length = UInt32(newMetadata.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(newMetadata)
        out.append(payload)
        return out
    }
}
