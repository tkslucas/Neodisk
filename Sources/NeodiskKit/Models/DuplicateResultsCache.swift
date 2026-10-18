// Persisted duplicate results, since hashing costs real I/O. Keyed on the `.ndscan` file's size and mtime (stable
// across launches, unlike ScanSnapshot.id) plus the minimum size, so a rescan discards the stale result.

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
    /// Bump when `findDuplicates` changes its output. v2 added `reclaimableBytes`, so v1 blobs no longer decode.
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
