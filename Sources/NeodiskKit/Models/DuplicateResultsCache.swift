//
//  DuplicateResultsCache.swift
//  Neodisk
//
//  The persisted form of a computed DuplicateScanResults, stored through the
//  snapshot cache's `.nddup` slot. Duplicate hashing reads real bytes off
//  disk (battery and I/O), so a finished run is worth keeping: reopening the
//  Duplicates tab after a scan, or relaunching, otherwise re-hashes the whole
//  candidate set. Persisting the finished result turns that into a small read.
//
//  The cache is keyed on the identity (size + mtime) of the current
//  `.ndscan` file it was derived from plus the minimum file size the scan
//  used. That key is content-stable across process launches (unlike
//  ScanSnapshot.id, a fresh UUID per decode), so a rescan (which rewrites the
//  file) changes the key and the stale result is discarded. A separate
//  duplicate-format version invalidates every blob at once if the finder's
//  semantics ever change.
//

import Foundation

/// Identity of the snapshot file a duplicate result was computed from, plus
/// the minimum file size — the content-stable key that decides a cache hit.
public nonisolated struct DuplicateResultsCacheKey: Codable, Equatable, Sendable {
    public let snapshotSize: Int64
    public let snapshotModified: Double
    public let minimumFileSize: Int64

    public init(snapshotSize: Int64, snapshotModified: Double, minimumFileSize: Int64) {
        self.snapshotSize = snapshotSize
        self.snapshotModified = snapshotModified
        self.minimumFileSize = minimumFileSize
    }
}

/// A computed duplicate result plus the key it is valid for, as stored on disk.
public nonisolated struct DuplicateResultsCacheEntry: Codable, Sendable {
    /// Finder semantics version. Bump when `DuplicateFinder.findDuplicates`
    /// changes what it emits so previously cached blobs are treated as misses.
    /// v2: groups carry `reclaimableBytes` (clone-aware reclaim accounting);
    /// v1 blobs lack the field and no longer decode.
    public static let currentDuplicateFormatVersion = 2

    public let dupFormatVersion: Int
    public let key: DuplicateResultsCacheKey
    /// When the run finished, for the tab's "Duplicates computed …" banner —
    /// the cache hit path never re-hashes, so the timestamp is carried here.
    public let computedAt: Date
    public let results: DuplicateScanResults

    public init(key: DuplicateResultsCacheKey, computedAt: Date, results: DuplicateScanResults) {
        self.dupFormatVersion = Self.currentDuplicateFormatVersion
        self.key = key
        self.computedAt = computedAt
        self.results = results
    }

    /// Whether this cached result is still valid for `key` (same snapshot
    /// file, same minimum file size, current duplicate format).
    public func isValid(for key: DuplicateResultsCacheKey) -> Bool {
        dupFormatVersion == Self.currentDuplicateFormatVersion && self.key == key
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoding(_ data: Data) -> DuplicateResultsCacheEntry? {
        try? JSONDecoder().decode(DuplicateResultsCacheEntry.self, from: data)
    }
}
