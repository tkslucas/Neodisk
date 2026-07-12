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
            #expect(group.wastedBytes == Int64(2 * Self.megabyte))
            #expect(results.totalWastedBytes == group.wastedBytes)
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
