import Foundation
import Testing
@testable import NeodiskKit

/// Cloud targets are keyed by `cloudscan://` identifiers, not filesystem
/// paths, so the codec must round-trip both the target URL (rebuilt via
/// `URL(string:)`) and node paths without absolutizing them into file URLs.
@Suite struct ScanSnapshotCodecCloudTests {
    @Test func testCloudTargetSnapshotRoundTrips() throws {
        let targetID = "cloudscan://google/12345"
        let target = ScanTarget(
            id: targetID,
            url: URL(string: targetID)!,
            displayName: "someone@example.com",
            kind: .cloud
        )

        let root = FileNodeRecord(
            id: target.id,
            path: target.id,
            name: target.displayName,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 900,
            logicalSize: 900,
            descendantFileCount: 2,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let doc = FileNodeRecord(
            id: "\(targetID)#abc",
            path: "\(targetID)/Report.pages",
            name: "Report.pages",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 500,
            logicalSize: 500,
            descendantFileCount: 1,
            lastModified: Date(timeIntervalSinceReferenceDate: 700_000_000),
            fileIdentity: .resourceIdentifier(Data("google:abc".utf8)),
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let photo = FileNodeRecord(
            id: "\(targetID)#def",
            path: "\(targetID)/Vacation.jpg",
            name: "Vacation.jpg",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 400,
            logicalSize: 400,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let children = [doc, photo]
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let snapshot = ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: Date(),
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: true,
            source: .live
        )

        let decoded = try ScanSnapshotCodec.decode(try ScanSnapshotCodec.encode(snapshot))

        #expect(decoded.target.kind == .cloud)
        #expect(decoded.target.id == targetID)
        #expect(decoded.target.displayName == "someone@example.com")
        #expect(decoded.target.url.absoluteString == targetID)
        #expect(decoded.treeStore.nodeCount == 3)

        let decodedDoc = try #require(decoded.treeStore.node(id: doc.id))
        #expect(decodedDoc.id == "\(targetID)#abc")
        // The path must survive verbatim — not absolutized into a file URL.
        #expect(decodedDoc.path == "\(targetID)/Report.pages")
        #expect(decodedDoc.name == "Report.pages")
        #expect(decodedDoc.allocatedSize == 500)
        #expect(decodedDoc.fileIdentity == .resourceIdentifier(Data("google:abc".utf8)))
    }
}
