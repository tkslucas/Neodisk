// Persisted diff (`.nddiff`), saving ~13s of decode and rebuild on reopen. Keyed on size and mtime of
// both snapshot files (stable across launches, unlike ScanSnapshot.id) plus the entry limit.

import Foundation

/// Identity of the two snapshot cache files a diff was computed from, plus
/// the entry limit — the content-stable key that decides a cache hit.
public nonisolated struct ScanChangeCacheKey: Codable, Equatable, Sendable {
    public let currentSize: Int64
    public let currentModified: Double
    public let previousSize: Int64
    public let previousModified: Double
    public let entryLimit: Int

    public init(
        currentSize: Int64,
        currentModified: Double,
        previousSize: Int64,
        previousModified: Double,
        entryLimit: Int
    ) {
        self.currentSize = currentSize
        self.currentModified = currentModified
        self.previousSize = previousSize
        self.previousModified = previousModified
        self.entryLimit = entryLimit
    }
}

/// A computed change list plus the key it is valid for, as stored on disk.
public nonisolated struct ScanChangeListCacheEntry: Codable, Sendable {
    /// Diff semantics version. Bump when `ScanChangeList.build` changes what
    /// it emits so previously cached blobs are treated as misses.
    public static let currentDiffFormatVersion = 1

    public let diffFormatVersion: Int
    public let key: ScanChangeCacheKey
    /// Carried here because the cache-hit path never decodes the previous snapshot.
    public let comparisonDate: Date?
    public let list: ScanChangeList

    public init(key: ScanChangeCacheKey, comparisonDate: Date?, list: ScanChangeList) {
        self.diffFormatVersion = Self.currentDiffFormatVersion
        self.key = key
        self.comparisonDate = comparisonDate
        self.list = list
    }

    /// Whether this cached diff is still valid for `key` (same files, same
    /// entry limit, current diff format).
    public func isValid(for key: ScanChangeCacheKey) -> Bool {
        diffFormatVersion == Self.currentDiffFormatVersion && self.key == key
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoding(_ data: Data) -> ScanChangeListCacheEntry? {
        try? JSONDecoder().decode(ScanChangeListCacheEntry.self, from: data)
    }
}
