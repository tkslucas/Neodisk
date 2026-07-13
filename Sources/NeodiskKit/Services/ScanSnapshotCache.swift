//
//  ScanSnapshotCache.swift
//  Neodisk
//
//  Persists the latest completed scan per location so reopening it shows the
//  previous results instantly while a background rescan refreshes them.
//
//  Each target keeps its latest scan (<hash>.ndscan) plus the one before it
//  (<hash>.prev.ndscan, rotated on save — the basis for "what grew since
//  last scan" diffs; a save whose tree content matches the latest skips the
//  rotation, so an unchanged rescan keeps the older baseline instead of
//  making the diff empty) in ~/Library/Application Support/Neodisk/ScanCache/,
//  named by a hash of the target path (the app runs unbundled, so the
//  directory is created explicitly rather than derived from a bundle
//  identifier). The format is versioned; corrupt or old-version files are
//  deleted on read and treated as cache misses. All encoding and decoding
//  happens on this actor, off the main thread, and each save is a single
//  non-suspending actor method ending in an atomic write — a scan finishing
//  while a previous write is still in flight simply queues behind it.
//

import CryptoKit
import Foundation

nonisolated enum ScanSnapshotCacheError: Error {
    case incompleteSnapshot
    case unsupportedFormat
    case unsupportedVersion(UInt32)
    case corruptData(String)
}

/// What the cache knows about a target at launch, from snapshot metadata
/// alone (no node payload is decoded).
public struct CachedScanInfo: Sendable {
    /// When the cached scan finished (falls back to its start date).
    public let lastScanDate: Date
    /// Wall-clock duration of the cached scan — the honest predictor of how
    /// long a rescan will take.
    public let lastScanDuration: TimeInterval?
    public let nodeCount: Int
    /// True when a rotated previous snapshot also exists (enables diffing).
    public let hasPreviousSnapshot: Bool

    public init(
        lastScanDate: Date,
        lastScanDuration: TimeInterval?,
        nodeCount: Int,
        hasPreviousSnapshot: Bool
    ) {
        self.lastScanDate = lastScanDate
        self.lastScanDuration = lastScanDuration
        self.nodeCount = nodeCount
        self.hasPreviousSnapshot = hasPreviousSnapshot
    }
}

/// What a save did to the cache slots: whether the prior latest rotated
/// into the previous slot, and whether a previous snapshot exists at all
/// afterwards (the truth behind `CachedScanInfo.hasPreviousSnapshot`).
public struct SnapshotSaveOutcome: Sendable {
    public let rotatedPrevious: Bool
    public let hasPreviousSnapshot: Bool
}

public actor ScanSnapshotCache {
    /// v3 adds the cloud-only bit (files) and cloudOnlyLogicalSize payload
    /// (directories); older builds reject v3 files cleanly as
    /// unsupportedVersion and rescan.
    static let currentFormatVersion: UInt32 = 3
    static let oldestReadableFormatVersion: UInt32 = 1
    private static let magic: UInt32 = 0x4E44_5343 // "NDSC"
    private static let fileExtension = "ndscan"
    private static let auxiliaryFileExtension = "ndaux"
    private static let changeListFileExtension = "nddiff"
    private static let duplicateResultsFileExtension = "nddup"

    private let directoryURL: URL
    private let isLoggingEnabled: Bool

    public nonisolated static var defaultDirectoryURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupportURL.appending(path: "Neodisk/ScanCache", directoryHint: .isDirectory)
    }

    public init(
        directoryURL: URL = ScanSnapshotCache.defaultDirectoryURL,
        isLoggingEnabled: Bool = true
    ) {
        self.directoryURL = directoryURL
        self.isLoggingEnabled = isLoggingEnabled
    }

    // MARK: - Public API

    /// Persists a completed snapshot as the latest cached scan for its
    /// target. The prior latest file (if any) rotates to the "previous"
    /// slot, so the last two *different* scans per location are available
    /// for diffing; anything older is dropped. A snapshot whose tree
    /// content matches the current latest still becomes the latest (fresh
    /// scan date and duration) but skips the rotation — rotating an
    /// identical tree would make every diff empty and destroy the baseline
    /// the rescan was meant to be compared against.
    @discardableResult
    public func save(_ snapshot: ScanSnapshot) throws -> SnapshotSaveOutcome {
        guard snapshot.isComplete else {
            throw ScanSnapshotCacheError.incompleteSnapshot
        }

        let start = ContinuousClock.now
        let digest = ScanChangeList.contentDigest(of: snapshot.treeStore)
        let data = try ScanSnapshotCodec.encode(
            snapshot,
            version: Self.currentFormatVersion,
            changeDigest: digest
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let latestURL = fileURL(forTargetID: snapshot.target.id)
        let previousURL = previousFileURL(forTargetID: snapshot.target.id)
        var rotatedPrevious = false
        if FileManager.default.fileExists(atPath: latestURL.path) {
            if latestMatches(digest: digest, targetID: snapshot.target.id, at: latestURL) {
                log("content unchanged for \(snapshot.target.id); keeping previous baseline")
            } else {
                try? FileManager.default.removeItem(at: previousURL)
                try? FileManager.default.moveItem(at: latestURL, to: previousURL)
                rotatedPrevious = true
            }
        }

        try data.write(to: latestURL, options: .atomic)
        log(
            "saved \(snapshot.treeStore.nodeCount) nodes (\(data.count) bytes) for "
            + "\(snapshot.target.id) in \(elapsedDescription(since: start))"
        )
        return SnapshotSaveOutcome(
            rotatedPrevious: rotatedPrevious,
            hasPreviousSnapshot: FileManager.default.fileExists(atPath: previousURL.path)
        )
    }

    /// True when the latest cache file records the same change-significant
    /// tree content (and target — filename hash collisions never match).
    /// Header-only read; files from before the digest existed, or ones that
    /// fail to read, never match and rotate as before.
    private func latestMatches(digest: String, targetID: String, at url: URL) -> Bool {
        guard let metadata = try? ScanSnapshotCodec.readMetadata(fromFileAt: url) else {
            return false
        }
        return metadata.targetPath == targetID && metadata.changeDigest == digest
    }

    /// Returns the cached snapshot for a target, or nil when there is none.
    /// Unreadable files (corruption, old format versions) are deleted so they
    /// never fail twice.
    public func loadSnapshot(for target: ScanTarget) -> ScanSnapshot? {
        loadSnapshot(for: target, at: fileURL(forTargetID: target.id))
    }

    /// Returns the rotated previous snapshot for a target — the scan before
    /// the one `loadSnapshot` returns — or nil when the target has only been
    /// scanned once.
    public func loadPreviousSnapshot(for target: ScanTarget) -> ScanSnapshot? {
        loadSnapshot(for: target, at: previousFileURL(forTargetID: target.id))
    }

    private func loadSnapshot(for target: ScanTarget, at url: URL) -> ScanSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let start = ContinuousClock.now
        do {
            let snapshot = try ScanSnapshotCodec.decode(data)
            guard snapshot.target.id == target.id else {
                // Filename hash collision or a moved cache directory; not our
                // snapshot, and not ours to delete.
                return nil
            }
            log(
                "loaded \(snapshot.treeStore.nodeCount) nodes for \(target.id) "
                + "in \(elapsedDescription(since: start))"
            )
            return snapshot
        } catch {
            log("discarding unreadable snapshot for \(target.id): \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Deletes cache entries whose target is no longer in the sidebar and
    /// returns what the cache knows about each surviving target. Called once
    /// at launch. Metadata comes from the latest snapshot only; previous
    /// snapshots contribute the `hasPreviousSnapshot` bit and are dropped
    /// when orphaned (target removed, or their latest file is gone).
    public func pruneAndIndex(keepingTargetIDs validTargetIDs: Set<String>) -> [String: CachedScanInfo] {
        var latestMetadataByPath: [String: ScanSnapshotCodec.Metadata] = [:]
        var previousTargetPaths: Set<String> = []
        var latestBasenames: Set<String> = []
        var previousURLsByBasename: [String: URL] = [:]

        for url in cacheFileURLs() {
            let isPrevious = Self.isPreviousSlot(url)
            do {
                let metadata = try ScanSnapshotCodec.readMetadata(fromFileAt: url)
                guard validTargetIDs.contains(metadata.targetPath) else {
                    log("pruning snapshot for removed location \(metadata.targetPath)")
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                if isPrevious {
                    previousTargetPaths.insert(metadata.targetPath)
                    previousURLsByBasename[Self.slotBasename(url)] = url
                } else {
                    latestMetadataByPath[metadata.targetPath] = metadata
                    latestBasenames.insert(Self.slotBasename(url))
                }
            } catch {
                log("pruning unreadable snapshot at \(url.lastPathComponent): \(error)")
                try? FileManager.default.removeItem(at: url)
            }
        }

        // A previous snapshot without its latest counterpart (the latest was
        // corrupt and deleted, or an old app version left it behind) is
        // unreachable for diffing — drop it.
        for (basename, url) in previousURLsByBasename where !latestBasenames.contains(basename) {
            log("pruning orphaned previous snapshot \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: url)
        }

        // Auxiliary payloads (kind stats, cached change lists) live and die
        // with their latest snapshot.
        for url in auxiliaryFileURLs() where !latestBasenames.contains(Self.slotBasename(url)) {
            log("pruning orphaned auxiliary data \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: url)
        }
        for url in changeListFileURLs() where !latestBasenames.contains(Self.slotBasename(url)) {
            log("pruning orphaned change-list cache \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: url)
        }
        for url in duplicateResultsFileURLs() where !latestBasenames.contains(Self.slotBasename(url)) {
            log("pruning orphaned duplicate-results cache \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: url)
        }

        var infoByPath: [String: CachedScanInfo] = [:]
        for (path, metadata) in latestMetadataByPath {
            let duration = metadata.finishedAt.map { $0.timeIntervalSince(metadata.startedAt) }
            infoByPath[path] = CachedScanInfo(
                lastScanDate: metadata.finishedAt ?? metadata.startedAt,
                lastScanDuration: duration.flatMap { $0 >= 0 ? $0 : nil },
                nodeCount: metadata.nodeCount,
                hasPreviousSnapshot: previousTargetPaths.contains(path)
            )
        }
        return infoByPath
    }

    // MARK: - Auxiliary data

    /// Opaque per-target payload stored alongside the latest snapshot (the
    /// UI keeps derived data like kind statistics here so restoring a
    /// snapshot doesn't recompute them). Removed and pruned with the
    /// snapshot; content and staleness checks are the caller's business.
    public func saveAuxiliaryData(_ data: Data, forTargetID targetID: String) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: auxiliaryFileURL(forTargetID: targetID), options: .atomic)
    }

    public func loadAuxiliaryData(forTargetID targetID: String) -> Data? {
        try? Data(contentsOf: auxiliaryFileURL(forTargetID: targetID))
    }

    // MARK: - Cached change list (`.nddiff` slot)

    /// The content-stable key for a target's cached diff: the identity of the
    /// current and rotated-previous snapshot files plus the entry limit. Nil
    /// when either snapshot file is missing (nothing to diff yet).
    public func changeListCacheKey(
        forTargetID targetID: String,
        entryLimit: Int
    ) -> ScanChangeCacheKey? {
        guard let current = fileSignature(at: fileURL(forTargetID: targetID)),
              let previous = fileSignature(at: previousFileURL(forTargetID: targetID)) else {
            return nil
        }
        return ScanChangeCacheKey(
            currentSize: current.size,
            currentModified: current.modified,
            previousSize: previous.size,
            previousModified: previous.modified,
            entryLimit: entryLimit
        )
    }

    /// Returns the persisted change list for a target only when it is still
    /// valid for the current snapshot files (same identity, entry limit, and
    /// diff format); otherwise nil so the caller recomputes.
    public func loadChangeList(
        forTargetID targetID: String,
        entryLimit: Int
    ) -> ScanChangeListCacheEntry? {
        guard let key = changeListCacheKey(forTargetID: targetID, entryLimit: entryLimit),
              let data = try? Data(contentsOf: changeListFileURL(forTargetID: targetID)),
              let entry = ScanChangeListCacheEntry.decoding(data),
              entry.isValid(for: key) else {
            return nil
        }
        return entry
    }

    /// Persists a computed change list, keyed on the current snapshot files.
    /// A no-op when the files it would key on are missing.
    public func saveChangeList(
        _ list: ScanChangeList,
        comparisonDate: Date?,
        forTargetID targetID: String,
        entryLimit: Int
    ) {
        guard let key = changeListCacheKey(forTargetID: targetID, entryLimit: entryLimit) else {
            return
        }
        let entry = ScanChangeListCacheEntry(key: key, comparisonDate: comparisonDate, list: list)
        guard let data = try? entry.encoded() else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: changeListFileURL(forTargetID: targetID), options: .atomic)
    }

    // MARK: - Cached duplicate results (`.nddup` slot)

    /// The content-stable key for a target's cached duplicate result: the
    /// identity of the current snapshot file plus the minimum file size the
    /// scan used. Nil when the snapshot file is missing (nothing scanned yet).
    public func duplicateResultsCacheKey(
        forTargetID targetID: String,
        minimumFileSize: Int64
    ) -> DuplicateResultsCacheKey? {
        guard let current = fileSignature(at: fileURL(forTargetID: targetID)) else {
            return nil
        }
        return DuplicateResultsCacheKey(
            snapshotSize: current.size,
            snapshotModified: current.modified,
            minimumFileSize: minimumFileSize
        )
    }

    /// Returns the persisted duplicate result for a target only when it is
    /// still valid for the current snapshot file (same identity, minimum file
    /// size, and duplicate format); otherwise nil so the caller can re-hash.
    public func loadDuplicateResults(
        forTargetID targetID: String,
        minimumFileSize: Int64
    ) -> DuplicateResultsCacheEntry? {
        guard let key = duplicateResultsCacheKey(forTargetID: targetID, minimumFileSize: minimumFileSize),
              let data = try? Data(contentsOf: duplicateResultsFileURL(forTargetID: targetID)),
              let entry = DuplicateResultsCacheEntry.decoding(data),
              entry.isValid(for: key) else {
            return nil
        }
        return entry
    }

    /// Persists a computed duplicate result, keyed on the current snapshot
    /// file. A no-op when the file it would key on is missing.
    public func saveDuplicateResults(
        _ results: DuplicateScanResults,
        computedAt: Date,
        forTargetID targetID: String,
        minimumFileSize: Int64
    ) {
        guard let key = duplicateResultsCacheKey(forTargetID: targetID, minimumFileSize: minimumFileSize) else {
            return
        }
        let entry = DuplicateResultsCacheEntry(key: key, computedAt: computedAt, results: results)
        guard let data = try? entry.encoded() else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: duplicateResultsFileURL(forTargetID: targetID), options: .atomic)
    }

    public func removeSnapshot(forTargetID targetID: String) {
        try? FileManager.default.removeItem(at: fileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: previousFileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: auxiliaryFileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: changeListFileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: duplicateResultsFileURL(forTargetID: targetID))
    }

    public func removeAll() {
        for url in cacheFileURLs() + auxiliaryFileURLs() + changeListFileURLs() + duplicateResultsFileURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total size of all cache files, for the Settings privacy tab.
    public func totalSizeOnDisk() -> Int64 {
        (cacheFileURLs() + auxiliaryFileURLs() + changeListFileURLs() + duplicateResultsFileURLs())
            .reduce(into: Int64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total = total.addingClamped(Int64(size))
            }
    }

    private func fileSignature(at url: URL) -> (size: Int64, modified: Double)? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = values.fileSize, let modified = values.contentModificationDate else {
            return nil
        }
        return (Int64(size), modified.timeIntervalSinceReferenceDate)
    }

    // MARK: - Files

    private func fileURL(forTargetID targetID: String) -> URL {
        directoryURL.appending(
            path: "\(Self.hashedName(forTargetID: targetID)).\(Self.fileExtension)",
            directoryHint: .notDirectory
        )
    }

    private func previousFileURL(forTargetID targetID: String) -> URL {
        directoryURL.appending(
            path: "\(Self.hashedName(forTargetID: targetID)).prev.\(Self.fileExtension)",
            directoryHint: .notDirectory
        )
    }

    private func auxiliaryFileURL(forTargetID targetID: String) -> URL {
        directoryURL.appending(
            path: "\(Self.hashedName(forTargetID: targetID)).\(Self.auxiliaryFileExtension)",
            directoryHint: .notDirectory
        )
    }

    private func changeListFileURL(forTargetID targetID: String) -> URL {
        directoryURL.appending(
            path: "\(Self.hashedName(forTargetID: targetID)).\(Self.changeListFileExtension)",
            directoryHint: .notDirectory
        )
    }

    private func duplicateResultsFileURL(forTargetID targetID: String) -> URL {
        directoryURL.appending(
            path: "\(Self.hashedName(forTargetID: targetID)).\(Self.duplicateResultsFileExtension)",
            directoryHint: .notDirectory
        )
    }

    private static func hashedName(forTargetID targetID: String) -> String {
        let digest = SHA256.hash(data: Data(targetID.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPreviousSlot(_ url: URL) -> Bool {
        url.deletingPathExtension().pathExtension == "prev"
    }

    /// The hashed-name part shared by a target's latest and previous files.
    private static func slotBasename(_ url: URL) -> String {
        var trimmed = url.deletingPathExtension()
        if trimmed.pathExtension == "prev" {
            trimmed = trimmed.deletingPathExtension()
        }
        return trimmed.lastPathComponent
    }

    private func cacheFileURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { $0.pathExtension == Self.fileExtension }
    }

    private func auxiliaryFileURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { $0.pathExtension == Self.auxiliaryFileExtension }
    }

    private func changeListFileURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { $0.pathExtension == Self.changeListFileExtension }
    }

    private func duplicateResultsFileURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { $0.pathExtension == Self.duplicateResultsFileExtension }
    }

    private func elapsedDescription(since start: ContinuousClock.Instant) -> String {
        (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))
    }

    private func log(_ message: String) {
        guard isLoggingEnabled else { return }
        FileHandle.standardError.write(Data("Neodisk ScanSnapshotCache: \(message)\n".utf8))
    }
}
