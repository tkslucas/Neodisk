//
//  ScanChangeListCache.swift
//  Neodisk
//
//  The persisted form of a computed ScanChangeList, stored through the
//  snapshot cache's `.nddiff` slot. Reopening the Changes tab after a scan
//  (or on relaunch) otherwise pays ~13s: decoding the previous snapshot plus
//  the O(nodes) ScanChangeList.build. Persisting the finished diff turns that
//  into a small read.
//
//  The cache is keyed on the identity (size + mtime) of BOTH snapshot cache
//  files it was derived from — the current `.ndscan` and the rotated
//  `.prev.ndscan` — plus the entry limit. That key is content-stable across
//  process launches (unlike ScanSnapshot.id, a fresh UUID per decode), so a
//  rescan (which rewrites and rotates the files) changes the key and the
//  stale diff is recomputed. A separate diff-format version invalidates every
//  blob at once if the diff's semantics ever change.
//

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
    /// The compared predecessor's finish date, for the tab's "since …"
    /// header — the cache hit path never decodes the previous snapshot, so it
    /// must be carried here.
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
