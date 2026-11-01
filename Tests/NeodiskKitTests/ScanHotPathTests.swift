import Testing
import Foundation
@testable import NeodiskKit

/// The scan hot path's string shortcuts must agree with the slow forms they
/// replace, and its scheduling pieces must keep slow work from blocking the rest.
@Suite struct ScanHotPathTests {
    @Test func lexicallyNormalPathsAreTheirOwnStandardization() {
        let normal = ["/", "/a", "/Users/me/Library", "/a/.hidden", "/a/...", "/a/b..c", "/a/.x./y", "/a b/c"]
        for path in normal {
            #expect(ScanExclusionMatcher.isLexicallyNormal(path), "\(path)")
            #expect(URL(fileURLWithPath: path).standardized.path == path, "\(path)")
        }
        let notNormal = ["", "a/b", "/a/", "//a", "/a//b", "/a/./b", "/a/../b", "/a/.", "/a/..", "/.", "/.."]
        for path in notNormal {
            #expect(!ScanExclusionMatcher.isLexicallyNormal(path), "\(path)")
        }
    }

    @Test func scanPathMatchesStandardizedPath() {
        let matcher = ScanExclusionMatcher(patterns: [], rootPath: "/Users/me", includeCloudStorage: false)
        for path in ["/Users/me/a", "/Users/me/a/../b", "/Users/me/./c", "/Users/me/d/"] {
            let url = URL(fileURLWithPath: path)
            #expect(matcher.scanPath(of: url) == url.standardized.path, "\(path)")
        }
    }

    @Test func cloudRootIsExcludedByNameAndOtherChildrenAreNot() {
        let matcher = ScanExclusionMatcher(patterns: [], rootPath: "/Users", includeCloudStorage: false)
        #expect(matcher.excludes(normalizedParentPath: "/Users/me/Library", childName: "CloudStorage", isDirectory: true))
        #expect(matcher.excludes(normalizedParentPath: "/Users/me/Library", childName: "Mobile Documents", isDirectory: true))
        #expect(!matcher.excludes(normalizedParentPath: "/Users/me/Library", childName: "Caches", isDirectory: true))
        #expect(!matcher.excludes(normalizedParentPath: "/Users/me/Documents", childName: "CloudStorage.txt", isDirectory: false))
    }

    #if canImport(Darwin)
    @Test func protectedContainersCoverOtherAppsContainers() {
        #expect(ProtectedContainers.contains("/Users/me/Library/Containers/com.app/Data"))
        #expect(ProtectedContainers.contains("/Users/me/Library/Group Containers/group.x/y"))
        #expect(!ProtectedContainers.contains("/Users/me/Library/Containers"))
        #expect(!ProtectedContainers.contains("/Users/me/Library/Caches/Containers/x"))
        #expect(ProtectedContainers.containsChildren(ofDirectory: "/Users/me/Library/Containers"))
        #expect(ProtectedContainers.containsChildren(ofDirectory: "/Users/me/Library/Group Containers"))
        #expect(!ProtectedContainers.containsChildren(ofDirectory: "/Users/me/Library"))
    }
    #endif

    @Test func listingCacheHandsEachListingOutOnceWithinItsBudget() {
        let cache = DirectoryListingCache(maximumEntryCount: 3)
        let child = BulkDirectoryChild(
            name: "a", metadata: nil, entryErrno: nil, isHidden: false, deviceID: nil, directoryMountStatus: 0
        )
        cache.store([child, child], forDirectory: "/x")
        cache.store([child, child], forDirectory: "/y")
        #expect(cache.take(forDirectory: "/y") == nil)
        #expect(cache.take(forDirectory: "/x")?.count == 2)
        #expect(cache.take(forDirectory: "/x") == nil)
        cache.store([child, child, child], forDirectory: "/y")
        #expect(cache.take(forDirectory: "/y")?.count == 3)
    }

    @Test func slowDirectoryReadDoesNotHoldQueuedReads() async throws {
        // Once the slow read holds its thread, it waits for every queued read to run on the other one; if
        // they waited behind it, it would give up instead (the bound only keeps a regression from hanging).
        let executor = DirectoryIOExecutor(workerCount: 2)
        let slowStarted = AsyncStream<Void>.makeStream()
        let fastReads = DispatchSemaphore(value: 0)
        let slow = Task {
            try await executor.run { _, _ in
                slowStarted.continuation.yield()
                let deadline = DispatchTime.now() + 60
                return (0..<20).allSatisfy { _ in fastReads.wait(timeout: deadline) == .success }
            }
        }
        for await _ in slowStarted.stream { break }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await executor.run { _, _ in fastReads.signal() } }
            }
            try await group.waitForAll()
        }
        #expect(try await slow.value)
    }

    /// Ids keep the URL's decomposed spelling, which snapshots and rescans rely on, even for composed names.
    @Test func folderIDsKeepTheURLSpellingOfComposedNames() async throws {
        let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "nd-nfc-\(UUID().uuidString)", directoryHint: .isDirectory)
        let composed = "Funda\u{00E7}\u{00E3}o"
        let folder = root.appending(path: composed, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: folder.appending(path: "file.txt"))

        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root, kind: .folder), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let store = try #require(finished?.treeStore)
        let folderNode = try #require(store.children(of: store.rootID).first { $0.isDirectory })
        let expected = root.appending(path: composed, directoryHint: .isDirectory)
        #expect(Array(folderNode.id.utf8) == Array(expected.path.utf8))
        #expect(Array(folderNode.name.utf8) == Array(expected.lastPathComponent.utf8))
    }
}

/// Decompression runs ahead on another thread; the parser must still get the exact payload in order.
@Suite struct PrefetchingPayloadSourceTests {
    private static func payload(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        // Compressible but not trivial: runs of random lengths.
        var data = Data()
        while data.count < count {
            let byte = UInt8.random(in: 0...255, using: &generator)
            data.append(contentsOf: [UInt8](repeating: byte, count: Int.random(in: 1...40, using: &generator)))
        }
        return data.prefix(count)
    }

    @Test func handsOverExactlyThePayloadAcrossChunks() throws {
        let original = Self.payload(3_000_123)
        var compressed = Data()
        try ScanSnapshotCodec.appendCompressedPayload(original, to: &compressed)
        let source = PrefetchingPayloadSource(
            source: try PayloadDecompressor(compressed: compressed),
            chunkSize: 4_096,
            depth: 2
        )
        var output = Data()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_000, alignment: 8)
        defer { buffer.deallocate() }
        while case let read = try source.read(into: buffer, count: 1_000), read > 0 {
            output.append(buffer.assumingMemoryBound(to: UInt8.self), count: read)
        }
        #expect(output == original)
        #expect(source.isFinished)
        #expect(source.producedCount == original.count)
    }

    @Test func truncatedPayloadStillFails() throws {
        var compressed = Data()
        try ScanSnapshotCodec.appendCompressedPayload(Self.payload(500_000), to: &compressed)
        let truncated = compressed.prefix(compressed.count / 2)
        let source = PrefetchingPayloadSource(source: try PayloadDecompressor(compressed: truncated), chunkSize: 8_192)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 8_192, alignment: 8)
        defer { buffer.deallocate() }
        #expect(throws: (any Error).self) {
            while try source.read(into: buffer, count: 8_192) > 0 {}
        }
    }
}
