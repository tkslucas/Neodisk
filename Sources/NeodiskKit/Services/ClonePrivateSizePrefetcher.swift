//
//  ClonePrivateSizePrefetcher.swift
//  Neodisk
//
//  Overlaps clone deduplication's per-member ATTR_CMNEXT_PRIVATESIZE reads with
//  traversal instead of paying them serially in the assemble tail. The bulk
//  pass already flags clone-family members (refCount > 1) during the walk; this
//  fetches each such member's private size in the background as it is
//  discovered, so by the time `CloneDeduplicator` runs the sizes are mostly
//  already cached. On a clone-heavy home dir that pass is hundreds of thousands
//  of getattrlist(2) calls (~8s), all of which can run in the traversal's idle
//  reader capacity.
//
//  Correctness is independent of what this caches: the deduplicator reads
//  `cache[path] ?? systemPrivateSize(path)`, which returns byte-identical values
//  to the un-overlapped path for every member. A member that was never
//  prefetched (or whose fetch failed) simply falls back to the synchronous read,
//  exactly as before. The cache only changes WHEN the syscall happens.
//

import Foundation

nonisolated final class ClonePrivateSizePrefetcher: @unchecked Sendable {
    private let fetch: CloneDeduplicator.PrivateSizeProvider
    private let queue: OperationQueue
    private let lock = NSLock()
    // Keyed by path to match the deduplicator's provider argument. The keys are
    // the same `String` instances the nodes already hold (COW-shared, not
    // copies), so this only adds the dictionary's own overhead — bounded by the
    // clone-member count, a small fraction of a scan's node array.
    private var cache: [String: Int64] = [:]
    private var cancelled = false

    init(
        workerLimit: Int,
        fetch: @escaping CloneDeduplicator.PrivateSizeProvider = CloneDeduplicator.systemPrivateSize
    ) {
        self.fetch = fetch
        let queue = OperationQueue()
        // Bounded like the assemble-time fetch, and .utility so these expensive
        // per-file reads yield to the traversal's getattrlistbulk readers and
        // fill their I/O-wait gaps rather than contending at the same priority.
        queue.maxConcurrentOperationCount = max(1, workerLimit)
        queue.qualityOfService = .utility
        self.queue = queue
    }

    /// Schedules private-size reads for one directory's clone-family members.
    /// Called on a traversal worker; returns immediately.
    ///
    /// Reading at discovery time rather than in the assemble tail widens the
    /// window between a file's size read and its use, but it is the same
    /// TOCTOU class the assemble-time read already had (a file can change
    /// between scan and finalize) — just sampled a different instant, not a new
    /// correctness hazard.
    func enqueue(paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.addOperation { [self] in
            for path in paths {
                lock.lock()
                let stop = cancelled
                lock.unlock()
                if stop { return }
                let size = fetch(path)
                guard let size else { continue }
                lock.lock()
                cache[path] = size
                lock.unlock()
            }
        }
    }

    /// Blocks until every scheduled read has finished and returns the cache.
    /// Called once at the start of assembly, after traversal has closed, so the
    /// only outstanding work is prefetch stragglers.
    func drain() -> [String: Int64] {
        queue.waitUntilAllOperationsAreFinished()
        lock.lock()
        defer { lock.unlock() }
        ScanSyscallTally.recordClonePrefetchCached(count: cache.count)
        return cache
    }

    /// Stops outstanding reads when the scan is cancelled or errors out, so a
    /// dead scan doesn't keep issuing getattrlist calls in the background.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.cancelAllOperations()
    }
}
