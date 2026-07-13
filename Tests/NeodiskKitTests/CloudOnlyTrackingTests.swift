import Foundation
import Testing
@testable import NeodiskKit

/// Cloud-only (dataless) tracking: file records derive their cloud share
/// from the dataless flag, directories roll it up, and the snapshot codec
/// round-trips both through the v3 format while older formats stay clean.
@Suite struct CloudOnlyTrackingTests {
    private func file(
        _ name: String,
        allocated: Int64,
        logical: Int64,
        isDataless: Bool = false
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: "/scan/\(name)",
            path: "/scan/\(name)",
            name: name,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: allocated,
            logicalSize: logical,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false,
            isDataless: isDataless
        )
    }

    @Test func testDatalessFileDerivesCloudOnlySizeFromLogicalSize() {
        let dataless = file("movie.mov", allocated: 0, logical: 414_124_907, isDataless: true)
        #expect(dataless.isDataless)
        #expect(dataless.cloudOnlyLogicalSize == 414_124_907)

        let local = file("notes.txt", allocated: 4096, logical: 900)
        #expect(!local.isDataless)
        #expect(local.cloudOnlyLogicalSize == 0)
    }

    @Test func testDirectoryRollsUpCloudOnlySizeAndIgnoresDatalessFlag() {
        let children = [
            file("a.pdf", allocated: 0, logical: 1_000, isDataless: true),
            file("b.pdf", allocated: 2_000, logical: 2_000),
            file("c.pdf", allocated: 0, logical: 3_000, isDataless: true),
        ]
        let directory = FileNodeRecord.directory(
            id: "/scan",
            url: URL(filePath: "/scan", directoryHint: .isDirectory),
            name: "scan",
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        #expect(directory.cloudOnlyLogicalSize == 4_000)
        // Directories never carry the per-file flag, even if a caller set it.
        #expect(!directory.isDataless)
    }

    @Test func testDisplayWeightAddsCloudOnlyShareOnlyWhenEnabled() {
        let dataless = file("movie.mov", allocated: 0, logical: 500, isDataless: true)
        #expect(dataless.displayWeight(includingCloudOnly: false) == 0)
        #expect(dataless.displayWeight(includingCloudOnly: true) == 500)

        let local = file("notes.txt", allocated: 4096, logical: 900)
        #expect(local.displayWeight(includingCloudOnly: false) == 4096)
        #expect(local.displayWeight(includingCloudOnly: true) == 4096)
    }

    private func makeSnapshot() -> ScanSnapshot {
        let children = [
            file("cloud.mov", allocated: 0, logical: 5_000, isDataless: true),
            file("local.mov", allocated: 3_000, logical: 3_000),
        ]
        let root = FileNodeRecord.directory(
            id: "/scan",
            url: URL(filePath: "/scan", directoryHint: .isDirectory),
            name: "scan",
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        return ScanSnapshot(
            target: ScanTarget(url: URL(filePath: "/scan", directoryHint: .isDirectory)),
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            source: .live
        )
    }

    @Test func testCodecRoundTripsDatalessFlagAndDirectoryRollup() throws {
        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(makeSnapshot()))

        let cloud = try #require(decoded.treeStore.node(id: "/scan/cloud.mov"))
        #expect(cloud.isDataless)
        #expect(cloud.cloudOnlyLogicalSize == 5_000)

        let local = try #require(decoded.treeStore.node(id: "/scan/local.mov"))
        #expect(!local.isDataless)
        #expect(local.cloudOnlyLogicalSize == 0)

        let root = try #require(decoded.treeStore.node(id: "/scan"))
        #expect(!root.isDataless)
        #expect(root.cloudOnlyLogicalSize == 5_000)
    }

    @Test func testMetadataCarriesCloudOnlyTotalWithoutDecodingPayload() throws {
        let data = try ScanSnapshotCodec.encode(makeSnapshot())
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cloud-meta-\(UUID().uuidString).ndscan")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try ScanSnapshotCodec.readMetadata(fromFileAt: url)
        #expect(metadata.cloudOnlyLogicalSize == 5_000)
    }

    @Test func testVersion2FilesDecodeWithoutCloudOnlyData() throws {
        let data = try ScanSnapshotCodec.encode(makeSnapshot(), version: 2)
        let decoded = try ScanSnapshotCodec.decode(data)

        let cloud = try #require(decoded.treeStore.node(id: "/scan/cloud.mov"))
        #expect(!cloud.isDataless)
        #expect(cloud.cloudOnlyLogicalSize == 0)

        let root = try #require(decoded.treeStore.node(id: "/scan"))
        #expect(root.cloudOnlyLogicalSize == 0)
    }
}
