//
//  ScanSyscallTally.swift
//  Neodisk
//
//  Diagnostic per-category syscall counters for the scan engine, gated behind
//  `NEODISK_SCAN_SYSCALLS=1` (separate from `NEODISK_SCAN_TIMING` so ordinary
//  timing runs pay nothing). Answers "does the engine issue more syscalls than
//  the getattrlistbulk floor, and where?" by counting directory opens,
//  getattrlistbulk calls, and entries returned at each call site, plus the
//  non-bulk metadata/clone reads. Compare against traversal-syscall-bench.c on
//  the same tree: the C replay's dir/file counts are the floor.
//
//  Counts are exact regardless of lock overhead; these runs are for volume, not
//  wall time, so a per-event lock is fine. Nothing here runs unless the flag is
//  set.
//

import Foundation
import os

nonisolated enum ScanSyscallCategory: Sendable {
    /// The main iterative traversal (`bulkDirectoryEntries`).
    case traversal
    /// The auto-summarize probe (`descendantAtomicProbeProfile`).
    case probe
    /// The auto-summary walk that collapses a directory to one node.
    case summary
    /// Compatibility/relist and anything else routed through the bulk reader.
    case other
}

nonisolated enum ScanSyscallTally {
    struct Counters: Sendable {
        var traversalOpens = 0, traversalBulkCalls = 0, traversalEntries = 0
        var probeOpens = 0, probeBulkCalls = 0, probeEntries = 0
        var summaryOpens = 0, summaryBulkCalls = 0, summaryEntries = 0
        var otherOpens = 0, otherBulkCalls = 0, otherEntries = 0
        /// Non-bulk `getattrlist(ATTR_CMNEXT_PRIVATESIZE)` reads in clone dedup.
        var cloneGetattrCalls = 0
        /// `ScanMetadataLoader.metadata` loads (resourceValues/lstat), i.e. any
        /// per-item metadata read outside the bulk pass.
        var metadataLoads = 0
        /// Lazy directory `fstat` fallbacks in the bulk reader (device probe).
        var fstatFallbacks = 0
        /// Clone private sizes prefetched during traversal (cache hits the
        /// clone-dedup pass then reuses instead of a serial getattrlist).
        var clonePrefetchCached = 0
    }

    static let isEnabled = ProcessInfo.processInfo.environment["NEODISK_SCAN_SYSCALLS"] == "1"

    private static let state = OSAllocatedUnfairLock(initialState: Counters())

    static func reset() {
        guard isEnabled else { return }
        state.withLock { $0 = Counters() }
    }

    /// One enumerated directory: one open, one close, `bulkCalls`
    /// getattrlistbulk calls, `entries` records returned.
    static func recordBulkDirectory(_ category: ScanSyscallCategory, bulkCalls: Int, entries: Int) {
        guard isEnabled else { return }
        state.withLock {
            switch category {
            case .traversal:
                $0.traversalOpens += 1; $0.traversalBulkCalls += bulkCalls; $0.traversalEntries += entries
            case .probe:
                $0.probeOpens += 1; $0.probeBulkCalls += bulkCalls; $0.probeEntries += entries
            case .summary:
                $0.summaryOpens += 1; $0.summaryBulkCalls += bulkCalls; $0.summaryEntries += entries
            case .other:
                $0.otherOpens += 1; $0.otherBulkCalls += bulkCalls; $0.otherEntries += entries
            }
        }
    }

    static func recordCloneGetattr(count: Int) {
        guard isEnabled, count > 0 else { return }
        state.withLock { $0.cloneGetattrCalls += count }
    }

    static func recordMetadataLoad() {
        guard isEnabled else { return }
        state.withLock { $0.metadataLoads += 1 }
    }

    static func recordFstatFallback() {
        guard isEnabled else { return }
        state.withLock { $0.fstatFallbacks += 1 }
    }

    static func recordClonePrefetchCached(count: Int) {
        guard isEnabled else { return }
        state.withLock { $0.clonePrefetchCached += count }
    }

    /// Emits one `NEODISK_SCAN_TIMING phase=syscalls …` line (parsed by the
    /// harness like the timing lines). Totals plus the per-category split.
    static func emit() {
        guard isEnabled else { return }
        let c = state.withLock { $0 }
        let totalOpens = c.traversalOpens + c.probeOpens + c.summaryOpens + c.otherOpens
        let totalBulk = c.traversalBulkCalls + c.probeBulkCalls + c.summaryBulkCalls + c.otherBulkCalls
        let totalEntries = c.traversalEntries + c.probeEntries + c.summaryEntries + c.otherEntries
        let line = "NEODISK_SCAN_TIMING phase=syscalls"
            + " opens=\(totalOpens) bulkCalls=\(totalBulk) entries=\(totalEntries)"
            + " travOpens=\(c.traversalOpens) travBulk=\(c.traversalBulkCalls) travEntries=\(c.traversalEntries)"
            + " probeOpens=\(c.probeOpens) probeBulk=\(c.probeBulkCalls) probeEntries=\(c.probeEntries)"
            + " sumOpens=\(c.summaryOpens) sumBulk=\(c.summaryBulkCalls) sumEntries=\(c.summaryEntries)"
            + " otherOpens=\(c.otherOpens) otherBulk=\(c.otherBulkCalls) otherEntries=\(c.otherEntries)"
            + " cloneGetattr=\(c.cloneGetattrCalls) clonePrefetchCached=\(c.clonePrefetchCached)"
            + " metadataLoads=\(c.metadataLoads) fstatFallbacks=\(c.fstatFallbacks)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
