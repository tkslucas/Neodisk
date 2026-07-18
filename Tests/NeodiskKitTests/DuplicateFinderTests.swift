import Foundation
import Testing
@testable import NeodiskKit

/// Exercises the finder against real files in a temp directory: hashing
/// reads actual contents, so fixtures live on disk.
@Suite struct DuplicateFinderTests {
    private static let megabyte = 1 << 20

    /// Contents big enough to clear the 1 MB minimum and (for the
    /// full-hash cases) the 256 KB prefix.
    private func bytes(seed: UInt8, count: Int, tailSeed: UInt8? = nil) -> Data {
        var data = Data(repeating: seed, count: count)
        if let tailSeed {
            // Same prefix, different tail: forces the full-content pass to
            // tell files apart.
            data.replaceSubrange((count - 16)..<count, with: Data(repeating: tailSeed, count: 16))
        }
        return data
    }

    /// A block of `seed` bytes with a distinct `patchSeed` run written at
    /// `offset`, used to make files that share a prefix (and sometimes a
    /// tail) but diverge at a chosen point.
    private func patched(seed: UInt8, count: Int, offset: Int, patchSeed: UInt8, length: Int = 64) -> Data {
        var data = Data(repeating: seed, count: count)
        data.replaceSubrange(offset..<(offset + length), with: Data(repeating: patchSeed, count: length))
        return data
    }

    private func makeStore(directory: URL, files: [(name: String, data: Data)]) throws -> FileTreeStore {
        var children: [FileNodeRecord] = []
        for file in files {
            let url = directory.appending(path: file.name)
            try file.data.write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let inode = (attributes[.systemFileNumber] as? UInt64)
                ?? UInt64(attributes[.systemFileNumber] as? Int ?? 0)
            children.append(FileNodeRecord(
                id: url.path,
                url: url,
                name: file.name,
                isDirectory: false,
                isSymbolicLink: false,
                allocatedSize: Int64(file.data.count),
                logicalSize: Int64(file.data.count),
                descendantFileCount: 1,
                lastModified: nil,
                fileIdentity: FileIdentity(device: 1, inode: inode),
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            ))
        }
        let root = FileNodeRecord.directory(
            id: directory.path,
            url: directory,
            name: directory.lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        return FileTreeStore(
            root: root,
            childrenByID: [directory.path: FileTreeStore.sortedChildren(children)]
        )
    }

    /// Store variant that pins each file's charged `allocatedSize` and
    /// `cloneInfo`, mirroring what the clone/hardlink deduplicators leave on
    /// the records the finder reads — the keeper carries the family's shared
    /// blocks, charged clone members carry ~0. The bytes on disk are written
    /// verbatim so the hashing ladder still confirms the group.
    private func makeStore(
        directory: URL,
        detailedFiles: [(name: String, data: Data, allocatedSize: Int64, cloneInfo: CloneInfo?)]
    ) throws -> FileTreeStore {
        var children: [FileNodeRecord] = []
        for file in detailedFiles {
            let url = directory.appending(path: file.name)
            try file.data.write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let inode = (attributes[.systemFileNumber] as? UInt64)
                ?? UInt64(attributes[.systemFileNumber] as? Int ?? 0)
            children.append(FileNodeRecord(
                id: url.path,
                url: url,
                name: file.name,
                isDirectory: false,
                isSymbolicLink: false,
                allocatedSize: file.allocatedSize,
                logicalSize: Int64(file.data.count),
                descendantFileCount: 1,
                lastModified: nil,
                fileIdentity: FileIdentity(device: 1, inode: inode),
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false,
                cloneInfo: file.cloneInfo
            ))
        }
        let root = FileNodeRecord.directory(
            id: directory.path,
            url: directory,
            name: directory.lastPathComponent,
            children: children,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )
        return FileTreeStore(
            root: root,
            childrenByID: [directory.path: FileTreeStore.sortedChildren(children)]
        )
    }

    private func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-dupes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    @Test func findsIdenticalFilesAndSkipsSameSizeDifferentContent() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0xAB, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("copy-1.bin", identical),
                ("copy-2.bin", identical),
                ("same-size-other.bin", bytes(seed: 0xCD, count: 2 * Self.megabyte)),
                ("unique.bin", bytes(seed: 0xEF, count: 3 * Self.megabyte)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.map { ($0 as NSString).lastPathComponent }.sorted()
                == ["copy-1.bin", "copy-2.bin"])
            #expect(group.fileSize == Int64(2 * Self.megabyte))
            // Independent copies, own blocks: reclaim is the naive figure.
            #expect(group.reclaimableBytes == Int64(2 * Self.megabyte))
            #expect(!group.isAllClones)
            #expect(results.totalWastedBytes == group.reclaimableBytes)
            #expect(results.unreadableCount == 0)
        }
    }

    @Test func identicalPrefixDifferentTailIsNotADuplicate() async throws {
        try await withTempDirectory { directory in
            // Same size and same first 256 KB, so both survive the prefix
            // pass; only the full-content hash can separate them.
            let store = try makeStore(directory: directory, files: [
                ("prefix-twin-1.bin", bytes(seed: 0x11, count: 2 * Self.megabyte, tailSeed: 0x22)),
                ("prefix-twin-2.bin", bytes(seed: 0x11, count: 2 * Self.megabyte, tailSeed: 0x33)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.isEmpty)
            #expect(results.candidateCount == 2)
        }
    }

    @Test func identicalHeadDifferentInsidePrefixIsNotADuplicate() async throws {
        try await withTempDirectory { directory in
            // Same first 4 KB (head tier collides) but they diverge at 100 KB,
            // still inside the 256 KB prefix, so the prefix tier separates them
            // without any full read.
            let store = try makeStore(directory: directory, files: [
                ("head-twin-1.bin", patched(seed: 0x11, count: 2 * Self.megabyte, offset: 100_000, patchSeed: 0x22)),
                ("head-twin-2.bin", patched(seed: 0x11, count: 2 * Self.megabyte, offset: 100_000, patchSeed: 0x33)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.isEmpty)
            #expect(results.candidateCount == 2)
        }
    }

    @Test func differingOnlyInTailIsNotADuplicate() async throws {
        try await withTempDirectory { directory in
            // Identical for the first 256 KB, diverging only in the final
            // bytes: the tail sample folded into the prefix tier catches it.
            let count = 2 * Self.megabyte
            let store = try makeStore(directory: directory, files: [
                ("tail-twin-1.bin", patched(seed: 0x44, count: count, offset: count - 100, patchSeed: 0x55)),
                ("tail-twin-2.bin", patched(seed: 0x44, count: count, offset: count - 100, patchSeed: 0x66)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.isEmpty)
            #expect(results.candidateCount == 2)
        }
    }

    @Test func differingOnlyInMiddleIsSeparatedByFullPass() async throws {
        try await withTempDirectory { directory in
            // Identical head and identical tail, diverging only in the middle
            // (past 256 KB from the start, before the last 256 KB): only the
            // full-content pass can tell them apart, and it must.
            let count = 2 * Self.megabyte
            let identicalCopy = bytes(seed: 0x77, count: count)
            let store = try makeStore(directory: directory, files: [
                ("mid-a.bin", identicalCopy),
                ("mid-a-copy.bin", identicalCopy),
                ("mid-b.bin", patched(seed: 0x77, count: count, offset: 1_000_000, patchSeed: 0x88)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            // The true pair groups; the middle-diverging near-twin is excluded.
            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.map { ($0 as NSString).lastPathComponent }.sorted()
                == ["mid-a-copy.bin", "mid-a.bin"])
        }
    }

    @Test func mediumFilesConfirmWithoutTailSampling() async throws {
        try await withTempDirectory { directory in
            // 100 KB files sit below the 256 KB tail threshold: the prefix
            // tier reads them whole and confirms without a tail read.
            let identical = bytes(seed: 0x12, count: 100 * 1024)
            let store = try makeStore(directory: directory, files: [
                ("med-1.bin", identical),
                ("med-2.bin", identical),
                ("med-other.bin", bytes(seed: 0x34, count: 100 * 1024)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store, minimumFileSize: 50 * 1024)

            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.count == 2)
            #expect(group.fileSize == Int64(100 * 1024))
        }
    }

    @Test func tinyFilesConfirmAtHeadTier() async throws {
        try await withTempDirectory { directory in
            // 2 KB files are fully covered by the 4 KB head hash and confirm
            // at the cheapest tier.
            let identical = bytes(seed: 0x56, count: 2 * 1024)
            let store = try makeStore(directory: directory, files: [
                ("tiny-1.bin", identical),
                ("tiny-2.bin", identical),
                ("tiny-other.bin", bytes(seed: 0x78, count: 2 * 1024)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store, minimumFileSize: 1024)

            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.count == 2)
            #expect(group.fileSize == Int64(2 * 1024))
        }
    }

    @Test func filesBelowMinimumSizeAreIgnored() async throws {
        try await withTempDirectory { directory in
            let small = bytes(seed: 0x42, count: 4096)
            let store = try makeStore(directory: directory, files: [
                ("small-1.bin", small),
                ("small-2.bin", small),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.isEmpty)
            #expect(results.candidateCount == 0)
        }
    }

    private func fileNode(url: URL, size: Int64) throws -> FileNodeRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? UInt64)
            ?? UInt64(attributes[.systemFileNumber] as? Int ?? 0)
        return FileNodeRecord(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: size,
            logicalSize: size,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: FileIdentity(device: 1, inode: inode),
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    @Test func nonRegularFilesAreSkippedNotHashed() async throws {
        try await withTempDirectory { directory in
            // Two real byte-identical twins that should still pair up.
            let identical = bytes(seed: 0x5A, count: 2 * Self.megabyte)
            var children: [FileNodeRecord] = []
            for name in ["twin-1.bin", "twin-2.bin"] {
                let url = directory.appending(path: name)
                try identical.write(to: url)
                children.append(try fileNode(url: url, size: Int64(identical.count)))
            }

            // A named pipe reporting the SAME logical size, so it lands in the
            // twins' same-size group. Opening and reading it would block
            // forever with no writer; the finder must skip it on the metadata
            // check and never open it. (This test hangs if the guard regresses.)
            let fifoURL = directory.appending(path: "pipe.bin")
            #expect(mkfifo(fifoURL.path, 0o644) == 0)
            children.append(try fileNode(url: fifoURL, size: Int64(2 * Self.megabyte)))

            let root = FileNodeRecord.directory(
                id: directory.path,
                url: directory,
                name: directory.lastPathComponent,
                children: children,
                lastModified: nil,
                isPackage: false,
                isAccessible: true
            )
            let store = FileTreeStore(
                root: root,
                childrenByID: [directory.path: FileTreeStore.sortedChildren(children)]
            )

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.count == 1)
            #expect(results.groups.first?.nodeIDs.count == 2)
            // The fifo survived size grouping but was skipped before hashing.
            #expect(results.unreadableCount == 1)
        }
    }

    @Test func hardLinksCollapseToOneCopy() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x7A, count: 2 * Self.megabyte)
            var store = try makeStore(directory: directory, files: [
                ("original.bin", identical),
                ("real-copy.bin", identical),
            ])

            // A hard link to original.bin: same content, same file identity —
            // it must not count as a third copy.
            let linkURL = directory.appending(path: "hard-link.bin")
            let originalURL = directory.appending(path: "original.bin")
            try FileManager.default.linkItem(at: originalURL, to: linkURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: originalURL.path)
            let inode = (attributes[.systemFileNumber] as? UInt64)
                ?? UInt64(attributes[.systemFileNumber] as? Int ?? 0)
            let linkNode = FileNodeRecord(
                id: linkURL.path,
                url: linkURL,
                name: "hard-link.bin",
                isDirectory: false,
                isSymbolicLink: false,
                allocatedSize: Int64(identical.count),
                logicalSize: Int64(identical.count),
                descendantFileCount: 1,
                lastModified: nil,
                fileIdentity: FileIdentity(device: 1, inode: inode),
                linkCount: 2,
                isPackage: false,
                isAccessible: true,
                isSelfAccessible: true,
                isSynthetic: false,
                isAutoSummarized: false
            )
            var children = store.children(of: directory.path)
            children.append(linkNode)
            let root = FileNodeRecord.directory(
                id: directory.path,
                url: directory,
                name: directory.lastPathComponent,
                children: children,
                lastModified: nil,
                isPackage: false,
                isAccessible: true
            )
            store = FileTreeStore(
                root: root,
                childrenByID: [directory.path: FileTreeStore.sortedChildren(children)]
            )

            let results = try await DuplicateFinder.findDuplicates(in: store)

            let group = try #require(results.groups.first)
            #expect(results.groups.count == 1)
            // Two distinct on-disk files, not three paths.
            #expect(group.nodeIDs.count == 2)
        }
    }

    @Test func vanishedFileCountsAsUnreadable() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x55, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("kept-1.bin", identical),
                ("kept-2.bin", identical),
                ("vanished-1.bin", bytes(seed: 0x66, count: 2 * Self.megabyte)),
                ("vanished-2.bin", bytes(seed: 0x66, count: 2 * Self.megabyte)),
            ])
            try FileManager.default.removeItem(at: directory.appending(path: "vanished-1.bin"))
            try FileManager.default.removeItem(at: directory.appending(path: "vanished-2.bin"))

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.count == 1)
            #expect(results.unreadableCount == 2)
        }
    }

    @Test func reportsMonotonicProgressEndingAtOne() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x99, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("p1.bin", identical),
                ("p2.bin", identical),
                ("p3.bin", bytes(seed: 0x98, count: 2 * Self.megabyte)),
            ])

            let collector = ProgressCollector()
            _ = try await DuplicateFinder.findDuplicates(in: store) { progress in
                collector.record(progress.fractionCompleted)
            }

            let fractions = collector.fractions()
            #expect(!fractions.isEmpty)
            #expect(fractions == fractions.sorted())
            #expect(fractions.last == 1.0)
        }
    }

    @Test func streamsPartialGroupsMatchingFinalResults() async throws {
        try await withTempDirectory { directory in
            // One pair per confirming tier: tiny (head hash covers the file),
            // medium (prefix pass covers it), large (full-content pass), plus
            // a same-size non-duplicate that must never stream.
            let tiny = bytes(seed: 0x01, count: 2 * 1024)
            let medium = bytes(seed: 0x02, count: 100 * 1024)
            let large = bytes(seed: 0x03, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("tiny-1.bin", tiny), ("tiny-2.bin", tiny),
                ("med-1.bin", medium), ("med-2.bin", medium),
                ("large-1.bin", large), ("large-2.bin", large),
                ("unique.bin", bytes(seed: 0x04, count: 2 * Self.megabyte)),
            ])

            let collector = PartialGroupsCollector()
            let results = try await DuplicateFinder.findDuplicates(
                in: store,
                minimumFileSize: 1024,
                onPartial: { collector.record($0) }
            )

            let batches = collector.batches()
            // Each tier reports the groups it confirmed: head, prefix, then
            // the full pass's collision group.
            #expect(batches.count == 3)
            #expect(batches.allSatisfy { !$0.isEmpty })
            // Batches are disjoint and their union is exactly the final groups.
            let streamed = batches.flatMap { $0 }
            #expect(streamed.count == Set(streamed.map(\.id)).count)
            #expect(streamed.sorted { $0.id < $1.id } == results.groups.sorted { $0.id < $1.id })
            #expect(results.groups.count == 3)
        }
    }

    /// Pins a file's access+modification time to whole seconds so its
    /// hash-cache stamp is reproducible after an in-place content swap.
    private func setModificationTime(_ url: URL, secondsSinceEpoch: Int) throws {
        var times = [
            timeval(tv_sec: secondsSinceEpoch, tv_usec: 0),
            timeval(tv_sec: secondsSinceEpoch, tv_usec: 0),
        ]
        guard utimes(url.path, &times) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Replaces a file's bytes without touching its size or inode, then
    /// restores the given mtime — the one change the mtime+size+inode stamp
    /// is documented not to catch.
    private func swapContentsInPlace(_ url: URL, with data: Data, restoringMtime seconds: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.close()
        try setModificationTime(url, secondsSinceEpoch: seconds)
    }

    @Test func hashCacheSkipsReadsForUnchangedStamps() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0xA1, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("a.bin", identical),
                ("b.bin", identical),
            ])
            let bURL = directory.appending(path: "b.bin")
            let pinnedSeconds = 1_700_000_000
            try setModificationTime(directory.appending(path: "a.bin"), secondsSinceEpoch: pinnedSeconds)
            try setModificationTime(bURL, secondsSinceEpoch: pinnedSeconds)

            let cache = DuplicateHashCache()
            let first = try await DuplicateFinder.findDuplicates(in: store, hashCache: cache)
            #expect(first.groups.count == 1)
            #expect(cache.entryCount == 2)

            // Swap b's bytes under an unchanged stamp: a cached run must
            // trust the stored digests and skip the reads entirely — stale
            // results are the proof the files weren't re-read.
            try swapContentsInPlace(
                bURL,
                with: bytes(seed: 0xB2, count: 2 * Self.megabyte),
                restoringMtime: pinnedSeconds
            )
            let cachedRun = try await DuplicateFinder.findDuplicates(in: store, hashCache: cache)
            #expect(cachedRun.groups == first.groups)

            // ...while a cache-less run reads the real bytes and splits them.
            let freshRun = try await DuplicateFinder.findDuplicates(in: store)
            #expect(freshRun.groups.isEmpty)
        }
    }

    @Test func hashCacheMissesWhenFileActuallyChanges() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0xC3, count: 2 * Self.megabyte)
            let store = try makeStore(directory: directory, files: [
                ("a.bin", identical),
                ("b.bin", identical),
            ])

            let cache = DuplicateHashCache()
            let first = try await DuplicateFinder.findDuplicates(in: store, hashCache: cache)
            #expect(first.groups.count == 1)

            // A normal edit moves mtime: the stamp misses and the changed
            // file re-hashes, so the pair correctly splits.
            let bURL = directory.appending(path: "b.bin")
            let handle = try FileHandle(forWritingTo: bURL)
            try handle.write(contentsOf: bytes(seed: 0xD4, count: 2 * Self.megabyte))
            try handle.close()

            let second = try await DuplicateFinder.findDuplicates(in: store, hashCache: cache)
            #expect(second.groups.isEmpty)
        }
    }

    @Test func testResultsCodableRoundTrip() throws {
        let results = DuplicateScanResults(
            groups: [
                DuplicateGroup(id: "h1-2048", fileSize: 2048, nodeIDs: ["/a/one", "/b/one"], reclaimableBytes: 2048),
                DuplicateGroup(id: "h2-4096", fileSize: 4096, nodeIDs: ["/a/two", "/b/two", "/c/two"], reclaimableBytes: 4096 * 2)
            ],
            totalWastedBytes: 2048 + 4096 * 2,
            candidateCount: 5,
            unreadableCount: 1
        )
        let data = try JSONEncoder().encode(results)
        let decoded = try JSONDecoder().decode(DuplicateScanResults.self, from: data)
        #expect(decoded == results)
        // The stored reclaim figure survives the round trip.
        #expect(decoded.groups.first?.reclaimableBytes == 2048)
    }

    /// A pre-clone-aware cache blob: its groups had no `reclaimableBytes`
    /// field. It must not decode as a valid entry, so a stale result can't
    /// resurface with an inflated reclaim figure after the schema change.
    @Test func staleCacheWithoutReclaimableBytesFailsToDecode() {
        let legacyJSON = """
        {"dupFormatVersion":1,"key":{"snapshotSize":1,"snapshotModified":2,"minimumFileSize":1048576},\
        "computedAt":0,"results":{"groups":[{"id":"h-100","fileSize":100,"nodeIDs":["/a","/b"]}],\
        "totalWastedBytes":100,"candidateCount":2,"unreadableCount":0}}
        """
        #expect(DuplicateResultsCacheEntry.decoding(Data(legacyJSON.utf8)) == nil)
        #expect(DuplicateResultsCacheEntry.currentDuplicateFormatVersion == 2)
    }

    @Test func clonedCopiesAreADuplicateGroupButReclaimNothing() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x5C, count: 2 * Self.megabyte)
            let size = Int64(identical.count)
            // Two byte-identical APFS clones: the store already charged the
            // path-second member ~0 (its private bytes), the keeper the full
            // shared blocks. Reclaim must come out near zero.
            let family = CloneInfo(device: 1, cloneID: 100, refCount: 2, privateSize: 0)
            let store = try makeStore(directory: directory, detailedFiles: [
                (name: "clone-a.bin", data: identical, allocatedSize: size, cloneInfo: family),
                (name: "clone-b.bin", data: identical, allocatedSize: 0, cloneInfo: family.withPrivateSize(0)),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            // Still a confirmed duplicate group (identical content)...
            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.count == 2)
            // ...but removing a clone frees nothing.
            #expect(group.reclaimableBytes == 0)
            #expect(group.isAllClones)
            #expect(results.totalWastedBytes == 0)
        }
    }

    @Test func mixedCloneAndRealCopyReclaimsOnlyTheRealCopy() async throws {
        try await withTempDirectory { directory in
            let identical = bytes(seed: 0x6D, count: 2 * Self.megabyte)
            let size = Int64(identical.count)
            let family = CloneInfo(device: 1, cloneID: 200, refCount: 2, privateSize: 0)
            // a & b are clones (store charged b to 0); d is an independent
            // byte-identical copy carrying its own blocks.
            let store = try makeStore(directory: directory, detailedFiles: [
                (name: "a.bin", data: identical, allocatedSize: size, cloneInfo: family),
                (name: "b.bin", data: identical, allocatedSize: 0, cloneInfo: family.withPrivateSize(0)),
                (name: "d.bin", data: identical, allocatedSize: size, cloneInfo: nil),
            ])

            let results = try await DuplicateFinder.findDuplicates(in: store)

            #expect(results.groups.count == 1)
            let group = try #require(results.groups.first)
            #expect(group.nodeIDs.count == 3)
            // Keeping the keeper frees b's ~0 clone bytes plus d's full size.
            #expect(group.reclaimableBytes == size)
            #expect(!group.isAllClones)
        }
    }
}

/// Partial-group callbacks arrive from an arbitrary executor; collect behind
/// a lock so the test can assert on the batches.
private final class PartialGroupsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[DuplicateGroup]] = []

    func record(_ groups: [DuplicateGroup]) {
        lock.lock()
        values.append(groups)
        lock.unlock()
    }

    func batches() -> [[DuplicateGroup]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Progress callbacks arrive from an arbitrary executor; collect behind a
/// lock so the test can assert on the sequence.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func fractions() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
