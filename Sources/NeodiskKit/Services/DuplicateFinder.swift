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
//  Confirmed groups stream out through `onPartial` as each tier (and, in
//  the full pass, each collision group) resolves, so the UI can show
//  results while hashing continues; the returned results stay the single
//  sorted source of truth.
//
//  An optional DuplicateHashCache carries per-file tier digests across
//  runs, keyed by size + mtime + inode, so a re-scan only reads files that
//  actually changed.
//
//  Read-only like everything else in the engine: files are opened for
//  reading, nothing is modified.
//

import CryptoKit
import Darwin
import Foundation

/// One set of files whose contents are byte-identical.
public struct DuplicateGroup: Sendable, Equatable, Identifiable, Codable {
    /// Content-derived: the confirming hash plus the file size.
    public let id: String
    /// Logical size of each copy.
    public let fileSize: Int64
    /// Node IDs (absolute paths) of the copies, sorted, one per distinct
    /// on-disk file — hard-linked aliases are already collapsed.
    public let nodeIDs: [String]
    /// Bytes actually freed by keeping one copy and deleting the rest — read
    /// off the store's clone/hardlink-deduplicated allocated sizes, not
    /// `fileSize * (count - 1)`. APFS clones share their on-disk blocks, so a
    /// removed clone frees only its private bytes; charging the group by the
    /// naive logical figure over-reports those groups. See
    /// `DuplicateFinder.reclaimableBytes`.
    public let reclaimableBytes: Int64

    /// The copies are byte-identical but free essentially nothing on removal:
    /// they are APFS clones of one another, sharing the same on-disk blocks.
    public var isAllClones: Bool {
        reclaimableBytes == 0 && nodeIDs.count > 1
    }

    public init(id: String, fileSize: Int64, nodeIDs: [String], reclaimableBytes: Int64) {
        self.id = id
        self.fileSize = fileSize
        self.nodeIDs = nodeIDs
        self.reclaimableBytes = reclaimableBytes
    }
}

public struct DuplicateScanResults: Sendable, Equatable, Codable {
    /// Confirmed groups, most reclaimable first.
    public let groups: [DuplicateGroup]
    /// Sum of every group's `reclaimableBytes` — the honest total that can be
    /// freed, with APFS-clone groups contributing only their private bytes.
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
    ///
    /// `onPartial` streams confirmed groups as they land — a batch per
    /// hashing tier for the small files it fully covers, then one batch per
    /// resolved collision group during the full-content pass — so callers
    /// can render results while hashing continues. Batches are disjoint and
    /// their union equals the returned `groups` (which alone are sorted);
    /// like `onProgress` it runs on an arbitrary executor.
    ///
    /// `hashCache` (optional) supplies per-file digests from previous runs:
    /// a file whose size + mtime + inode still match its cached stamp skips
    /// the read for any tier it was hashed at before, and fresh digests are
    /// recorded back. The caller owns loading and persisting the cache.
    public static func findDuplicates(
        in store: FileTreeStore,
        minimumFileSize: Int64 = defaultMinimumFileSize,
        hashCache: DuplicateHashCache? = nil,
        onProgress: (@Sendable (DuplicateScanProgress) -> Void)? = nil,
        onPartial: (@Sendable ([DuplicateGroup]) -> Void)? = nil
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
        // The same stat also yields each candidate's freshness stamp (size +
        // mtime + inode), which keys the hash-cache lookups below.
        var skippedUnhashable = 0
        var stampByPath: [String: DuplicateHashCache.FileStamp] = [:]
        var readableCandidates: [(size: Int64, nodes: [FileNodeRecord])] = []
        readableCandidates.reserveCapacity(candidates.count)
        for (size, nodes) in candidates {
            try Task.checkCancellation()
            var readable: [FileNodeRecord] = []
            for node in nodes {
                if let stamp = hashableStamp(node.path) {
                    readable.append(node)
                    stampByPath[node.path] = stamp
                } else {
                    skippedUnhashable += 1
                }
            }
            if readable.count >= 2 {
                readableCandidates.append((size, readable))
            }
        }
        candidates = readableCandidates
        let stamps = stampByPath

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
            let digest = try await cachingDigest(hashCache, .head, node.path, stamps[node.path]) {
                try hashHead(of: node.path, size: size)
            }
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
        var headConfirmed: [DuplicateGroup] = []
        for (key, members) in headGroups {
            if members.count < 2 {
                await progress.drop(bytes: members.reduce(Int64(0)) {
                    $0 + prefixTierBytes($1.size) + fullTierBytes($1.size)
                })
                continue
            }
            if members[0].size <= Int64(headHashLength) {
                headConfirmed.append(makeGroup(id: key, members: members))
            } else {
                needPrefixHash.append(contentsOf: members)
            }
        }
        confirmed.append(contentsOf: headConfirmed)
        if !headConfirmed.isEmpty { onPartial?(headConfirmed) }

        // 4. Prefix-hash pass (256 KB head + 256 KB tail) over head colliders.
        let prefixResults = try await hashConcurrently(needPrefixHash) { node, size in
            let digest = try await cachingDigest(hashCache, .prefix, node.path, stamps[node.path]) {
                try hashHeadAndTail(of: node.path, size: size)
            }
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
        // Pre-group key (size + head+tail hash) per needFullHash entry, so
        // the full pass can confirm each collision group the moment its last
        // member finishes instead of waiting for the whole pass.
        var fullPreKeys: [String] = []
        var pendingByPreKey: [String: Int] = [:]
        var subgroups: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
        for entry in prefixResults.hashed {
            subgroups["\(entry.size)-\(entry.digest)", default: []].append((entry.node, entry.size))
        }
        var prefixConfirmed: [DuplicateGroup] = []
        for (key, members) in subgroups {
            if members.count < 2 {
                await progress.drop(bytes: members.reduce(Int64(0)) {
                    $0 + fullTierBytes($1.size)
                })
                continue
            }
            if members[0].size <= Int64(prefixHashLength) {
                prefixConfirmed.append(makeGroup(id: key, members: members))
            } else {
                needFullHash.append(contentsOf: members)
                fullPreKeys.append(contentsOf: repeatElement(key, count: members.count))
                pendingByPreKey[key] = members.count
            }
        }
        confirmed.append(contentsOf: prefixConfirmed)
        if !prefixConfirmed.isEmpty { onPartial?(prefixConfirmed) }

        // 5. Full-content pass only where the head+tail sample still collided.
        // Confirmation happens per pre-group as its members complete: an
        // unreadable member still counts down, so a vanished file never
        // holds back the rest of its group.
        var finishedByPreKey: [String: [(node: FileNodeRecord, size: Int64, digest: String?)]] = [:]
        let fullResults = try await hashConcurrently(needFullHash, work: { node, size in
            // Not routed through cachingDigest: a miss reports progress per
            // chunk as the file streams, so only the hit charges tier bytes.
            let stamp = stamps[node.path]
            if let hashCache, let stamp,
               let cached = hashCache.cachedDigest(for: node.path, tier: .full, stamp: stamp) {
                await progress.add(bytes: fullTierBytes(size))
                return cached
            }
            let digest = try await hashFullContents(of: node.path) { chunkBytes in
                await progress.add(bytes: chunkBytes)
            }
            if let hashCache, let stamp {
                hashCache.storeDigest(digest, for: node.path, tier: .full, stamp: stamp)
            }
            return digest
        }, onEntryFinished: { index, node, size, digest in
            let key = fullPreKeys[index]
            finishedByPreKey[key, default: []].append((node, size, digest))
            pendingByPreKey[key, default: 0] -= 1
            guard pendingByPreKey[key] == 0 else { return }
            let members = finishedByPreKey.removeValue(forKey: key) ?? []
            var byDigest: [String: [(node: FileNodeRecord, size: Int64)]] = [:]
            for member in members {
                guard let digest = member.digest else { continue }
                byDigest["\(member.size)-\(digest)", default: []].append((member.node, member.size))
            }
            var newGroups: [DuplicateGroup] = []
            for (groupKey, copies) in byDigest where copies.count >= 2 {
                newGroups.append(makeGroup(id: groupKey, members: copies))
            }
            guard !newGroups.isEmpty else { return }
            confirmed.append(contentsOf: newGroups)
            onPartial?(newGroups)
        })
        unreadableCount += fullResults.unreadable.count

        await progress.finish()

        confirmed.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
            return $0.id < $1.id
        }
        return DuplicateScanResults(
            groups: confirmed,
            totalWastedBytes: confirmed.reduce(0) { $0.addingClamped($1.reclaimableBytes) },
            candidateCount: candidateCount,
            unreadableCount: unreadableCount
        )
    }

    /// Builds a confirmed group and its honest reclaim figure from the member
    /// records: the node IDs sorted for a stable identity, and reclaimable
    /// bytes read off the store's deduplicated allocated sizes.
    private static func makeGroup(
        id: String,
        members: [(node: FileNodeRecord, size: Int64)]
    ) -> DuplicateGroup {
        DuplicateGroup(
            id: id,
            fileSize: members[0].size,
            nodeIDs: members.map(\.node.id).sorted(),
            reclaimableBytes: reclaimableBytes(of: members.map(\.node))
        )
    }

    /// Bytes actually freed by keeping one copy of a confirmed group and
    /// deleting the rest. The store's `allocatedSize` is already clone- and
    /// hardlink-deduplicated (`CloneDeduplicator`/`HardLinkDeduplicator`), so
    /// a clone family's shared blocks are charged once — to its largest
    /// member. Keeping that largest-charged member and summing the rest is the
    /// real reclaim: a pure clone family nets ~0 (its other members hold only
    /// private bytes), while independent byte-identical copies each contribute
    /// their full size, exactly as before.
    private static func reclaimableBytes(of members: [FileNodeRecord]) -> Int64 {
        let sizes = members.map(\.allocatedSize)
        let total = sizes.reduce(Int64(0)) { $0.addingClamped($1) }
        return max(0, total - (sizes.max() ?? 0))
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
    /// the scan. `onEntryFinished` (with the entry's index in `entries`, and
    /// a nil digest for unreadable entries) is called serially from the
    /// caller's context as each entry completes, in completion order.
    private static func hashConcurrently(
        _ entries: [(node: FileNodeRecord, size: Int64)],
        work: @escaping @Sendable (FileNodeRecord, Int64) async throws -> String,
        onEntryFinished: ((_ index: Int, _ node: FileNodeRecord, _ size: Int64, _ digest: String?) -> Void)? = nil
    ) async throws -> HashPassResults {
        var results = HashPassResults()
        try await withThrowingTaskGroup(
            of: (index: Int, node: FileNodeRecord, size: Int64, digest: String?).self
        ) { group in
            var iterator = entries.enumerated().makeIterator()
            var inFlight = 0

            func addNext() -> Bool {
                guard let (index, entry) = iterator.next() else { return false }
                group.addTask {
                    do {
                        let digest = try await work(entry.node, entry.size)
                        return (index, entry.node, entry.size, digest)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, entry.node, entry.size, nil)
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
                onEntryFinished?(finished.index, finished.node, finished.size, finished.digest)
                try Task.checkCancellation()
                if addNext() { inFlight += 1 }
            }
        }
        return results
    }

    /// Metadata-only readiness gate: a candidate is safe to hash only when
    /// it's a regular file whose bytes are on disk right now. `stat` touches
    /// inode metadata alone — it never opens the file, never blocks on a
    /// provider, and never triggers a download. Dataless (cloud-only) files
    /// are refused so a paused or offline provider can't stall the scan.
    /// A hashable file's stamp doubles as its hash-cache freshness key.
    private static func hashableStamp(_ path: String) -> DuplicateHashCache.FileStamp? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        guard info.st_flags & BSDFileFlags.dataless == 0 else { return nil }
        return DuplicateHashCache.FileStamp(
            size: Int64(info.st_size),
            modifiedAtNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino)
        )
    }

    /// Cache-through wrapper for one tier's digest: a hit under a fresh
    /// stamp skips `compute` (and its disk read) entirely; a miss computes
    /// and records the digest for the next run. With no cache or no stamp
    /// it degrades to plain compute.
    private static func cachingDigest(
        _ cache: DuplicateHashCache?,
        _ tier: DuplicateHashCache.Tier,
        _ path: String,
        _ stamp: DuplicateHashCache.FileStamp?,
        compute: () async throws -> String
    ) async throws -> String {
        if let cache, let stamp,
           let cached = cache.cachedDigest(for: path, tier: tier, stamp: stamp) {
            return cached
        }
        let digest = try await compute()
        if let cache, let stamp {
            cache.storeDigest(digest, for: path, tier: tier, stamp: stamp)
        }
        return digest
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
