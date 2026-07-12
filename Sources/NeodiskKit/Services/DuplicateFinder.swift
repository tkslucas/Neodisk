//
//  DuplicateFinder.swift
//  Neodisk
//
//  Finds files with identical content in a scanned tree: group by size,
//  then confirm candidates through a cheap-first hashing ladder — a 4 KB
//  head hash, then a 256 KB head+tail hash, then a full content hash only
//  where the coarser tiers still collide — so the disk reads stay
//  proportional to plausible duplicates, not to the scan. Each tier only
//  sub-partitions the previous one; the full-content hash remains the sole
//  confirmation that two files are actually byte-identical. Hard links are
//  one file, not duplicates, and are collapsed by file identity up front.
//
//  Read-only like everything else in the engine: files are opened for
//  reading, nothing is modified.
//

import CryptoKit
import Darwin
import Foundation

/// One set of files whose contents are byte-identical.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
    /// Content-derived: the confirming hash plus the file size.
    public let id: String
    /// Logical size of each copy.
    public let fileSize: Int64
    /// Node IDs (absolute paths) of the copies, sorted, one per distinct
    /// on-disk file — hard-linked aliases are already collapsed.
    public let nodeIDs: [String]

    /// Bytes freed by keeping one copy and deleting the rest.
    public var wastedBytes: Int64 {
        fileSize * Int64(nodeIDs.count - 1)
    }

    public init(id: String, fileSize: Int64, nodeIDs: [String]) {
        self.id = id
        self.fileSize = fileSize
        self.nodeIDs = nodeIDs
    }
}

public struct DuplicateScanResults: Sendable, Equatable {
    /// Confirmed groups, biggest waste first.
    public let groups: [DuplicateGroup]
    public let totalWastedBytes: Int64
    /// Files that survived size grouping and were considered for hashing.
    public let candidateCount: Int
    /// Candidates dropped because their contents couldn't be read (moved,
    /// deleted, or protected since the scan).
    public let unreadableCount: Int

    public init(groups: [DuplicateGroup], totalWastedBytes: Int64, candidateCount: Int, unreadableCount: Int) {
        self.groups = groups
        self.totalWastedBytes = totalWastedBytes
        self.candidateCount = candidateCount
        self.unreadableCount = unreadableCount
    }
}

public struct DuplicateScanProgress: Sendable, Equatable {
    /// Monotonic 0...1 across the hashing tiers, weighted by bytes read.
    public let fractionCompleted: Double

    public init(fractionCompleted: Double) {
        self.fractionCompleted = fractionCompleted
    }
}

public enum DuplicateFinder {
    /// Files below this size are ignored: small files duplicate constantly
    /// (configs, icons, node_modules) and reclaim next to nothing.
    public static let defaultMinimumFileSize: Int64 = 1 << 20 // 1 MB

    /// Length of the cheapest tier's head hash. Splits the common
    /// "same size, different content" case at 1/64th of the prefix pass I/O.
    static let headHashLength = 1 << 12 // 4 KB
    /// Prefix length of the middle tier's head hash.
    static let prefixHashLength = 1 << 18 // 256 KB
    /// Length of the middle tier's tail sample, folded into the same key as
    /// the prefix so files that diverge near the end split without a full read.
    static let tailHashLength = 1 << 18 // 256 KB
    /// Streaming chunk size of the full-content pass, reused across reads.
    private static let fullHashChunkSize = 1 << 22 // 4 MB
    /// Concurrent hashing width — enough to keep an SSD busy without
    /// starving the rest of the app of I/O.
    private static let maxConcurrentReads = 6

    /// Scans a tree store for content-identical files. Runs entirely off
    /// the snapshot plus fresh reads of the candidate files; cancellation
    /// (via the surrounding task) throws `CancellationError`. `onProgress`
    /// is called on an arbitrary executor with a monotonic fraction.
    public static func findDuplicates(
        in store: FileTreeStore,
        minimumFileSize: Int64 = defaultMinimumFileSize,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws -> DuplicateScanResults {
        // 1. Same-size grouping over the snapshot — no I/O yet. Only real,
        // readable files count: directories (incl. packages), symlinks, and
        // synthetic nodes never join a group.
        var bySize: [Int64: [FileNodeRecord]] = [:]
        for node in store.allNodes {
            guard !node.isDirectory, !node.isSymbolicLink, !node.isSynthetic,
                  node.isSelfAccessible, node.logicalSize >= minimumFileSize else { continue }
            bySize[node.logicalSize, default: []].append(node)
        }

        // 2. Collapse hard links: aliases of one on-disk file share a
        // FileIdentity and are one copy, not duplicates. Groups need two
        // distinct files to stay interesting.
        var candidates: [(size: Int64, nodes: [FileNodeRecord])] = []
        for (size, nodes) in bySize where nodes.count >= 2 {
            var seenIdentities = Set<FileIdentity>()
            var distinct: [FileNodeRecord] = []
            for node in nodes {
                if let identity = node.fileIdentity {
                    guard seenIdentities.insert(identity).inserted else { continue }
                }
                distinct.append(node)
            }
            if distinct.count >= 2 {
                candidates.append((size, distinct))
            }
        }

        // 2b. Drop candidates whose bytes we must not, or cannot, read before
        // any file is opened. Cloud placeholders (SF_DATALESS: iCloud, Google
        // Drive, OneDrive and other File Providers) block on read while the
        // provider materializes them from the network — slowly, or forever
        // when offline or throttled — and that read has no cancellation
        // escape, so a handful of them wedge every hashing worker and the
        // scan stops progressing. Non-regular files (fifo/socket/device) and
        // files that vanished since the scan can't be hashed either. A
        // metadata-only stat decides all three without opening the file, so a
        // stalled provider can never wedge a worker. A group needs two
        // distinct readable files left to stay interesting.
        var skippedUnhashable = 0
        var readableCandidates: [(size: Int64, nodes: [FileNodeRecord])] = []
        readableCandidates.reserveCapacity(candidates.count)
        for (size, nodes) in candidates {
            try Task.checkCancellation()
            var readable: [FileNodeRecord] = []
            for node in nodes {
                if isHashable(node.path) {
                    readable.append(node)
                } else {
                    skippedUnhashable += 1
                }
            }
            if readable.count >= 2 {
                readableCandidates.append((size, readable))
            }
        }
        candidates = readableCandidates

        let candidateCount = candidates.reduce(0) { $0 + $1.nodes.count }

        // Progress is bytes-based and monotonic: the planned total starts
        // pessimistic (every candidate charged for all three tiers — 4 KB
        // head, 256 KB head+tail, full read) and only ever shrinks as each
        // tier rules files out, so the fraction never moves backwards.
        let progress = ProgressAccounting(
            plannedBytes: candidates.reduce(Int64(0)) { total, group in
                let perFile = headTierBytes(group.size)
                    + prefixTierBytes(group.size)
                    + fullTierBytes(group.size)
                return total + perFile * Int64(group.nodes.count)
            },
            onProgress: onProgress
        )

        var confirmed: [DuplicateGroup] = []

        // 3. Head-hash pass (4 KB) over every candidate — the cheapest split.
        let headResults = try await hashConcurrently(
            candidates.flatMap { group in group.nodes.map { (node: $0, size: group.size) } }
        ) { node, size in
            let digest = try hashHead(of: node.path, size: size)
            await progress.add(bytes: headTierBytes(size))
            return digest
        }
        var unreadableCount = skippedUnhashable + headResults.unreadable.count
        // A file that failed its head read reaches no later tier.
        await progress.drop(bytes: headResults.unreadable.reduce(Int64(0)) {
            $0 + prefixTierBytes($1.size) + fullTierBytes($1.size)
        })

        // Regroup by (size, head hash). Files fully covered by the head
        // (size <= 4 KB) confirm here; the rest advance to the prefix tier.
        var needPrefixHash: [(node: FileNodeRecord, size: Int64)] = []
        var headGroups: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
        for entry in headResults.hashed {
            headGroups["\(entry.size)-\(entry.digest)", default: []].append((entry.node, entry.size))
        }
        for (key, members) in headGroups {
            if members.count < 2 {
                await progress.drop(bytes: members.reduce(Int64(0)) {
                    $0 + prefixTierBytes($1.size) + fullTierBytes($1.size)
                })
                continue
            }
            if members[0].size <= Int64(headHashLength) {
                confirmed.append(DuplicateGroup(
                    id: key,
                    fileSize: members[0].size,
                    nodeIDs: members.map(\.node.id).sorted()
                ))
            } else {
                needPrefixHash.append(contentsOf: members)
            }
        }

        // 4. Prefix-hash pass (256 KB head + 256 KB tail) over head colliders.
        let prefixResults = try await hashConcurrently(needPrefixHash) { node, size in
            let digest = try hashHeadAndTail(of: node.path, size: size)
            await progress.add(bytes: prefixTierBytes(size))
            return digest
        }
        unreadableCount += prefixResults.unreadable.count
        await progress.drop(bytes: prefixResults.unreadable.reduce(Int64(0)) {
            $0 + fullTierBytes($1.size)
        })

        // Regroup by (size, head+tail hash). Files fully covered by the head
        // (size <= 256 KB) confirm here; the rest advance to the full pass.
        var needFullHash: [(node: FileNodeRecord, size: Int64)] = []
        var subgroups: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
        for entry in prefixResults.hashed {
            subgroups["\(entry.size)-\(entry.digest)", default: []].append((entry.node, entry.size))
        }
        for (key, members) in subgroups {
            if members.count < 2 {
                await progress.drop(bytes: members.reduce(Int64(0)) {
                    $0 + fullTierBytes($1.size)
                })
                continue
            }
            if members[0].size <= Int64(prefixHashLength) {
                confirmed.append(DuplicateGroup(
                    id: key,
                    fileSize: members[0].size,
                    nodeIDs: members.map(\.node.id).sorted()
                ))
            } else {
                needFullHash.append(contentsOf: members)
            }
        }

        // 5. Full-content pass only where the head+tail sample still collided.
        let fullResults = try await hashConcurrently(needFullHash) { node, size in
            let digest = try await hashFullContents(of: node.path) { chunkBytes in
                await progress.add(bytes: chunkBytes)
            }
            _ = size
            return digest
        }
        unreadableCount += fullResults.unreadable.count

        var fullGroups: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
        for entry in fullResults.hashed {
            fullGroups["\(entry.size)-\(entry.digest)", default: []].append((entry.node, entry.size))
        }
        for (key, members) in fullGroups where members.count >= 2 {
            confirmed.append(DuplicateGroup(
                id: key,
                fileSize: members[0].size,
                nodeIDs: members.map(\.node.id).sorted()
            ))
        }

        await progress.finish()

        confirmed.sort {
            if $0.wastedBytes != $1.wastedBytes { return $0.wastedBytes > $1.wastedBytes }
            return $0.id < $1.id
        }
        return DuplicateScanResults(
            groups: confirmed,
            totalWastedBytes: confirmed.reduce(0) { $0 + $1.wastedBytes },
            candidateCount: candidateCount,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Planned-bytes accounting
    //
    // Pure per-file byte costs, shared by the pessimistic plan and by the
    // `drop` calls that shrink it as each tier rules a file out, so the two
    // always agree and the fraction stays monotonic.

    /// Bytes the head (4 KB) tier reads for a file of `size`.
    private static func headTierBytes(_ size: Int64) -> Int64 {
        min(size, Int64(headHashLength))
    }

    /// Bytes the prefix (256 KB head + 256 KB tail) tier reads. Zero when the
    /// head tier already covered the whole file (`size <= headHashLength`).
    private static func prefixTierBytes(_ size: Int64) -> Int64 {
        guard size > Int64(headHashLength) else { return 0 }
        let head = min(size, Int64(prefixHashLength))
        let tail = size > Int64(prefixHashLength) ? min(size, Int64(tailHashLength)) : 0
        return head + tail
    }

    /// Bytes the full pass reads. Zero unless the file is larger than the
    /// prefix tier, since smaller files confirm without a full read.
    private static func fullTierBytes(_ size: Int64) -> Int64 {
        size > Int64(prefixHashLength) ? size : 0
    }

    // MARK: - Hashing

    private struct HashPassResults {
        var hashed: [(node: FileNodeRecord, size: Int64, digest: String)] = []
        var unreadable: [(node: FileNodeRecord, size: Int64)] = []
    }

    /// Runs `work` over the entries with bounded concurrency; a thrown
    /// non-cancellation error marks the entry unreadable instead of failing
    /// the scan.
    private static func hashConcurrently(
        _ entries: [(node: FileNodeRecord, size: Int64)],
        work: @escaping @Sendable (FileNodeRecord, Int64) async throws -> String
    ) async throws -> HashPassResults {
        var results = HashPassResults()
        try await withThrowingTaskGroup(
            of: (node: FileNodeRecord, size: Int64, digest: String?).self
        ) { group in
            var iterator = entries.makeIterator()
            var inFlight = 0

            func addNext() -> Bool {
                guard let entry = iterator.next() else { return false }
                group.addTask {
                    do {
                        let digest = try await work(entry.node, entry.size)
                        return (entry.node, entry.size, digest)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (entry.node, entry.size, nil)
                    }
                }
                return true
            }

            while inFlight < maxConcurrentReads, addNext() { inFlight += 1 }
            while let finished = try await group.next() {
                inFlight -= 1
                if let digest = finished.digest {
                    results.hashed.append((finished.node, finished.size, digest))
                } else {
                    results.unreadable.append((finished.node, finished.size))
                }
                try Task.checkCancellation()
                if addNext() { inFlight += 1 }
            }
        }
        return results
    }

    /// `st_flags` bit set on File Provider placeholders whose contents are
    /// not materialized locally (sys/stat.h `SF_DATALESS`). Reading such a
    /// file forces a network download; we refuse to, so a paused or offline
    /// provider can't stall the scan.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Metadata-only readiness gate: a candidate is safe to hash only when
    /// it's a regular file whose bytes are on disk right now. `stat` touches
    /// inode metadata alone — it never opens the file, never blocks on a
    /// provider, and never triggers a download.
    private static func isHashable(_ path: String) -> Bool {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return false }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        return info.st_flags & datalessFlag == 0
    }

    /// Hashes the first `headHashLength` bytes (or the whole file if smaller).
    private static func hashHead(of path: String, size: Int64) throws -> String {
        let fd = try openUncached(path)
        defer { close(fd) }
        let length = Int(min(size, Int64(headHashLength)))
        let head = try readExactly(fd: fd, offset: 0, count: length)
        var hasher = SHA256()
        head.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().hexString
    }

    /// Hashes the first `prefixHashLength` bytes and, for files larger than
    /// that, folds in the last `tailHashLength` bytes so tail divergence
    /// splits the group without reading the middle.
    private static func hashHeadAndTail(of path: String, size: Int64) throws -> String {
        let fd = try openUncached(path)
        defer { close(fd) }
        var hasher = SHA256()
        let headLength = Int(min(size, Int64(prefixHashLength)))
        let head = try readExactly(fd: fd, offset: 0, count: headLength)
        head.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        if size > Int64(prefixHashLength) {
            let tailLength = Int(min(size, Int64(tailHashLength)))
            let tail = try readExactly(fd: fd, offset: off_t(size - Int64(tailLength)), count: tailLength)
            tail.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().hexString
    }

    private static func hashFullContents(
        of path: String,
        onChunk: (Int64) async -> Void
    ) async throws -> String {
        let fd = try openUncached(path, readahead: true)
        defer { close(fd) }
        var hasher = SHA256()
        // One buffer reused across every chunk instead of a fresh Data alloc.
        var buffer = [UInt8](repeating: 0, count: fullHashChunkSize)
        while true {
            try Task.checkCancellation()
            let count = try buffer.withUnsafeMutableBytes { raw -> Int in
                let n = read(fd, raw.baseAddress, fullHashChunkSize)
                if n < 0 { throw posixError() }
                return n
            }
            if count == 0 { break }
            buffer.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: count))
            }
            await onChunk(Int64(count))
        }
        return hasher.finalize().hexString
    }

    // MARK: - Raw uncached reads
    //
    // All three tiers read through raw descriptors opened with F_NOCACHE so a
    // full-disk dedup scan never evicts the user's page cache. The full pass
    // adds F_RDAHEAD for its long sequential streaming.

    /// Opens `path` read-only with caching disabled. The caller owns the
    /// returned descriptor and must `close` it.
    private static func openUncached(_ path: String, readahead: Bool = false) throws -> Int32 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw posixError() }
        _ = fcntl(fd, F_NOCACHE, 1)
        if readahead { _ = fcntl(fd, F_RDAHEAD, 1) }
        return fd
    }

    /// Reads up to `count` bytes at `offset` via `pread`, looping over short
    /// reads. Returns fewer bytes only at EOF.
    private static func readExactly(fd: Int32, offset: off_t, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let total = try buffer.withUnsafeMutableBytes { raw -> Int in
            var got = 0
            while got < count {
                let n = pread(fd, raw.baseAddress?.advanced(by: got), count - got, offset + off_t(got))
                if n < 0 { throw posixError() }
                if n == 0 { break }
                got += n
            }
            return got
        }
        if total < count { buffer.removeLast(count - total) }
        return buffer
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Serializes byte counters for the two hashing passes and forwards a
/// throttled, monotonic fraction to the caller.
private actor ProgressAccounting {
    private var plannedBytes: Int64
    private var completedBytes: Int64 = 0
    private var lastReportedFraction = 0.0
    private let onProgress: (@Sendable (DuplicateScanProgress) -> Void)?

    init(plannedBytes: Int64, onProgress: (@Sendable (DuplicateScanProgress) -> Void)?) {
        self.plannedBytes = max(plannedBytes, 1)
        self.onProgress = onProgress
    }

    func add(bytes: Int64) {
        completedBytes += bytes
        report()
    }

    /// Work that turned out unnecessary (prefix pass ruled the file out):
    /// shrinking the plan keeps the fraction meaningful without ever moving
    /// it backwards.
    func drop(bytes: Int64) {
        plannedBytes = max(plannedBytes - bytes, completedBytes, 1)
        report()
    }

    func finish() {
        completedBytes = plannedBytes
        report(force: true)
    }

    private func report(force: Bool = false) {
        guard let onProgress else { return }
        let fraction = min(1, Double(completedBytes) / Double(plannedBytes))
        guard force || fraction - lastReportedFraction >= 0.01 else { return }
        lastReportedFraction = fraction
        onProgress(DuplicateScanProgress(fractionCompleted: fraction))
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
