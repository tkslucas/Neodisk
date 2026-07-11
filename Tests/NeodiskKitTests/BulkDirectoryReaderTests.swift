import Testing
import Foundation
@testable import NeodiskKit

/// The bulk reader must classify children the same way the
/// FileManager + URLResourceValues path does — these tests pin that parity.
@Suite struct BulkDirectoryReaderTests {
    @Test func testReadsBasicEntriesWithMetadata() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "file.bin")
        try Data(repeating: 0xAB, count: 10_000).write(to: fileURL)
        try FileManager.default.createDirectory(
            at: rootURL.appending(path: "folder", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "link"),
            withDestinationURL: fileURL
        )

        let children = try readBulkChildren(of: rootURL)
        #expect(children.count == 3)

        let file = try #require(children["file.bin"]?.metadata)
        #expect(!file.isDirectory)
        #expect(!file.isSymbolicLink)
        #expect(file.logicalSize == 10_000)
        #expect(file.allocatedSize >= 10_000)
        #expect(file.isReadable)
        #expect(file.linkCount == 1)
        #expect(file.fileIdentity == nil)
        let modified = try #require(file.lastModified)
        #expect(abs(modified.timeIntervalSinceNow) < 120)

        let folder = try #require(children["folder"]?.metadata)
        #expect(folder.isDirectory)
        #expect(!folder.isPackage)
        #expect(folder.logicalSize == 0)
        #expect(folder.allocatedSize == 0)

        let link = try #require(children["link"]?.metadata)
        #expect(link.isSymbolicLink)
        #expect(!link.isDirectory)
    }

    @Test func testRenameTrackingIdentityCapture() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: rootURL.appending(path: "folder", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        try Data(
            repeating: 0xCD,
            count: Int(ScanSizeBaseline.renameTrackingMinimumFileSize)
        ).write(to: rootURL.appending(path: "big.bin"))
        try Data(repeating: 0xEF, count: 512).write(to: rootURL.appending(path: "small.bin"))

        let children = try readBulkChildren(of: rootURL)

        // Directories and files at/above the rename-tracking threshold
        // carry their device+inode identity; small single-link files skip
        // it to keep snapshots lean.
        let folder = try #require(children["folder"]?.metadata)
        #expect(folder.fileIdentity?.isFileSystemIdentity == true)
        let big = try #require(children["big.bin"]?.metadata)
        #expect(big.fileIdentity?.isFileSystemIdentity == true)
        let small = try #require(children["small.bin"]?.metadata)
        #expect(small.fileIdentity == nil)
    }

    @Test func testHardLinkedFilesCarrySharedFileSystemIdentity() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original")
        try Data(repeating: 0x01, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(
            at: originalURL,
            to: rootURL.appending(path: "hardlink")
        )

        let children = try readBulkChildren(of: rootURL)
        let original = try #require(children["original"]?.metadata)
        let hardlink = try #require(children["hardlink"]?.metadata)

        #expect(original.linkCount == 2)
        #expect(hardlink.linkCount == 2)
        let originalIdentity = try #require(original.fileIdentity)
        #expect(originalIdentity.isFileSystemIdentity)
        #expect(originalIdentity == hardlink.fileIdentity)
    }

    @Test func testHiddenClassificationMatchesFileManager() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data("dot".utf8).write(to: rootURL.appending(path: ".dotfile"))
        try Data("plain".utf8).write(to: rootURL.appending(path: "visible"))
        let flaggedURL = rootURL.appending(path: "flagged")
        try Data("flagged".utf8).write(to: flaggedURL)
        var flaggedValues = URLResourceValues()
        flaggedValues.isHidden = true
        var mutableFlaggedURL = flaggedURL
        try mutableFlaggedURL.setResourceValues(flaggedValues)

        let children = try readBulkChildren(of: rootURL)
        #expect(children[".dotfile"]?.isHidden == true)
        #expect(children["flagged"]?.isHidden == true)
        #expect(children["visible"]?.isHidden == false)

        // FileManager's skipsHiddenFiles must agree with the bulk verdicts.
        let visibleByFileManager = Set(
            try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent)
        )
        let visibleByBulk = Set(
            children.values.filter { !$0.isHidden }.map(\.name)
        )
        #expect(visibleByBulk == visibleByFileManager)
    }

    @Test func testPackageClassificationMatchesResourceValues() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for name in ["Sample.app", "Thing.bundle", "Plain.d", "NoExtension", "Fake.framework"] {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }

        let children = try readBulkChildren(of: rootURL)
        for name in ["Sample.app", "Thing.bundle", "Plain.d", "NoExtension", "Fake.framework"] {
            let childURL = rootURL.appending(path: name, directoryHint: .isDirectory)
            let expected = try childURL.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false
            let bulkVerdict = try #require(children[name]?.metadata?.isPackage)
            #expect(bulkVerdict == expected, "package mismatch for \(name)")
        }
    }

    @Test func testUnicodeAndManyEntriesSurviveBatching() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var expectedNames: Set<String> = []
        for index in 0..<2_500 {
            let name = "file-\(index)-日本語-émoji🎈"
            try Data("x".utf8).write(to: rootURL.appending(path: name))
            expectedNames.insert(name)
        }

        let children = try readBulkChildren(of: rootURL)
        #expect(Set(children.keys) == expectedNames)
        #expect(children.values.allSatisfy { $0.metadata?.logicalSize == 1 })
    }

    @Test func testSizesAndCountsMatchResourceValuesAcrossRealDirectory() throws {
        // A real system directory exercises attribute combinations a synthetic
        // fixture can't (packages, odd flags, varying sizes).
        let rootURL = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        let children = try readBulkChildren(of: rootURL)
        #expect(children.count > 10)

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .linkCountKey
        ]
        var comparedCount = 0
        for child in children.values.prefix(300) {
            guard let metadata = child.metadata else { continue }
            let childURL = rootURL.appending(path: child.name)
            guard let values = try? childURL.resourceValues(forKeys: resourceKeys) else { continue }
            comparedCount += 1

            #expect(metadata.isDirectory == (values.isDirectory ?? false), "isDirectory mismatch: \(child.name)")
            #expect(metadata.isSymbolicLink == (values.isSymbolicLink ?? false), "isSymbolicLink mismatch: \(child.name)")
            if metadata.isDirectory {
                #expect(metadata.isPackage == (values.isPackage ?? false), "isPackage mismatch: \(child.name)")
            }
            if !metadata.isDirectory && !metadata.isSymbolicLink {
                #expect(metadata.logicalSize == Int64(values.fileSize ?? 0), "logicalSize mismatch: \(child.name)")
                if let allocated = values.totalFileAllocatedSize {
                    #expect(metadata.allocatedSize == Int64(allocated), "allocatedSize mismatch: \(child.name)")
                }
                #expect(metadata.linkCount == UInt64(max(values.linkCount ?? 1, 1)), "linkCount mismatch: \(child.name)")
            }
        }
        #expect(comparedCount > 10)
    }

    /// End-to-end pin: a full scan through the bulk path must produce the
    /// same tree (IDs, sizes, counts, package handling, dedup) as the
    /// FileManager fallback path.
    @Test func testFullScanMatchesFileManagerPath() async throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedURL = rootURL.appending(path: "nested/deeper", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 5_000).write(to: nestedURL.appending(path: "data.bin"))
        try Data(repeating: 0x22, count: 300).write(to: rootURL.appending(path: "small.txt"))
        try Data("dot".utf8).write(to: rootURL.appending(path: ".hidden"))

        let packageBinaryURL = rootURL.appending(path: "Sample.app/Contents/MacOS/Binary")
        try FileManager.default.createDirectory(
            at: packageBinaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x33, count: 2_048).write(to: packageBinaryURL)

        let originalURL = rootURL.appending(path: "nested/original")
        try Data(repeating: 0x44, count: 8_192).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: rootURL.appending(path: "hardlink"))
        try FileManager.default.createSymbolicLink(
            at: rootURL.appending(path: "link"),
            withDestinationURL: originalURL
        )

        var options = ScanOptions()
        options.exclusionPatterns = ["*.txt"]

        let target = ScanTarget(url: rootURL)
        let bulkSnapshot = try await lastSnapshot(
            engine: ScanEngine(bulkEnumerationEnabled: true),
            target: target,
            options: options
        )
        let fallbackSnapshot = try await lastSnapshot(
            engine: ScanEngine(bulkEnumerationEnabled: false),
            target: target,
            options: options
        )

        // The FileManager enumerator spells children of /var/... as
        // /private/var/... while the scan root and the bulk path keep the
        // target's /var spelling (a pre-existing fallback inconsistency).
        // Compare under the canonical spelling.
        func canonicalID(_ id: String) -> String {
            id.hasPrefix("/private/var/") ? String(id.dropFirst("/private".count)) : id
        }

        let bulkStore = bulkSnapshot.treeStore
        let fallbackStore = fallbackSnapshot.treeStore
        let bulkNodesByID = Dictionary(
            uniqueKeysWithValues: bulkStore.allNodes.map { (canonicalID($0.id), $0) }
        )
        let fallbackNodesByID = Dictionary(
            uniqueKeysWithValues: fallbackStore.allNodes.map { (canonicalID($0.id), $0) }
        )
        #expect(Set(bulkNodesByID.keys) == Set(fallbackNodesByID.keys))
        for (id, fallbackNode) in fallbackNodesByID {
            let bulkNode = try #require(bulkNodesByID[id], "missing node \(id)")
            #expect(bulkNode.logicalSize == fallbackNode.logicalSize, "logicalSize mismatch \(id)")
            #expect(bulkNode.allocatedSize == fallbackNode.allocatedSize, "allocatedSize mismatch \(id)")
            #expect(bulkNode.isDirectory == fallbackNode.isDirectory, "isDirectory mismatch \(id)")
            #expect(bulkNode.isPackage == fallbackNode.isPackage, "isPackage mismatch \(id)")
            #expect(bulkNode.isSymbolicLink == fallbackNode.isSymbolicLink, "isSymbolicLink mismatch \(id)")
            #expect(bulkNode.descendantFileCount == fallbackNode.descendantFileCount, "fileCount mismatch \(id)")
            #expect(bulkNode.linkCount == fallbackNode.linkCount, "linkCount mismatch \(id)")
        }
        #expect(bulkSnapshot.aggregateStats.fileCount == fallbackSnapshot.aggregateStats.fileCount)
        #expect(bulkSnapshot.aggregateStats.directoryCount == fallbackSnapshot.aggregateStats.directoryCount)
        #expect(bulkSnapshot.aggregateStats.totalAllocatedSize == fallbackSnapshot.aggregateStats.totalAllocatedSize)
        #expect(bulkSnapshot.aggregateStats.totalLogicalSize == fallbackSnapshot.aggregateStats.totalLogicalSize)
    }

    @Test func testMissingDirectoryThrowsOpenFailure() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appending(path: "bulk-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(throws: BulkDirectoryReadError.self) {
            _ = try BulkDirectoryReader.children(ofDirectory: missingURL, cancellationCheck: {})
        }
    }

    @Test func testCancellationPropagates() throws {
        let rootURL = try makeBulkTestDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data("x".utf8).write(to: rootURL.appending(path: "file"))

        struct TestCancellation: Error {}
        #expect(throws: TestCancellation.self) {
            _ = try BulkDirectoryReader.children(
                ofDirectory: rootURL,
                cancellationCheck: { throw TestCancellation() }
            )
        }
    }
}

private func lastSnapshot(
    engine: ScanEngine,
    target: ScanTarget,
    options: ScanOptions
) async throws -> ScanSnapshot {
    var snapshot: ScanSnapshot?
    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let finished) = event {
            snapshot = finished
        }
    }
    return try #require(snapshot)
}

private func readBulkChildren(of url: URL) throws -> [String: BulkDirectoryChild] {
    let children = try BulkDirectoryReader.children(ofDirectory: url, cancellationCheck: {})
    return Dictionary(uniqueKeysWithValues: children.map { ($0.name, $0) })
}

private func makeBulkTestDirectory() throws -> URL {
    // realpath the temp root: FileManager's enumerator canonicalizes
    // /var/... to /private/var/... for children while the scan root keeps
    // the /var spelling; starting from the canonical path keeps node IDs
    // comparable across both enumeration paths.
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let canonicalPath = temporaryPath.withCString { pointer -> String in
        guard let resolved = realpath(pointer, nil) else { return temporaryPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    let url = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        .appending(path: "bulk-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
