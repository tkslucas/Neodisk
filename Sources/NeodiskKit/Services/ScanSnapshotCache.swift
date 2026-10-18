// Keeps the latest and previous scan per location; an unchanged rescan skips the rotation so diffs never go empty.
// Heavy encode/decode runs detached so the actor stays free; slot mutations never suspend, so readers see whole states.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
    /// On-disk bytes of the cached scan's root, for sidebar summaries.
    public let totalAllocatedSize: Int64
    /// Dataless bytes below the root; 0 for caches written before the field existed.
    public let cloudOnlyLogicalSize: Int64

    public init(
        lastScanDate: Date,
        lastScanDuration: TimeInterval?,
        nodeCount: Int,
        hasPreviousSnapshot: Bool,
        totalAllocatedSize: Int64 = 0,
        cloudOnlyLogicalSize: Int64 = 0
    ) {
        self.lastScanDate = lastScanDate
        self.lastScanDuration = lastScanDuration
        self.nodeCount = nodeCount
        self.hasPreviousSnapshot = hasPreviousSnapshot
        self.totalAllocatedSize = totalAllocatedSize
        self.cloudOnlyLogicalSize = cloudOnlyLogicalSize
    }
}

/// Whether a save rotated the prior latest into the previous slot, and whether a previous slot exists afterwards.
public struct SnapshotSaveOutcome: Sendable {
    public let rotatedPrevious: Bool
    public let hasPreviousSnapshot: Bool
}

/// Compact comparison shared by persistence and both changes views. Holds no trees.
public final class PreparedScanComparison: Sendable {
    public let baseline: ScanSizeBaseline
    public let list: ScanChangeList

    init(baseline: ScanSizeBaseline, list: ScanChangeList) {
        self.baseline = baseline
        self.list = list
    }
}

public actor ScanSnapshotCache {
    /// v3 adds cloud-only bits and sizes, v5 summarized directories' clone families; older builds reject
    /// newer files as unsupportedVersion and rescan.
    static let currentFormatVersion: UInt32 = 5
    static let oldestReadableFormatVersion: UInt32 = 1
    private static let magic: UInt32 = 0x4E44_5343 // "NDSC"
    private static let fileExtension = "ndscan"
    private static let auxiliaryFileExtension = "ndaux"
    private static let changeListFileExtension = "nddiff"
    private static let duplicateResultsFileExtension = "nddup"
    private static let duplicateHashCacheFileName = "duplicate-hashes.ndhash"

    private let directoryURL: URL
    private let isLoggingEnabled: Bool

    /// Saves still encoding off the actor, so a finished scan is never invisible mid-save. Also gates the
    /// write: a removal or newer save while the encode ran drops the stale bytes.
    private var savingByTargetID: [String: ScanSnapshot] = [:]
    private struct ComparisonBuild {
        let id: UUID
        let key: ScanChangeCacheKey
        let snapshotID: UUID
        let task: Task<PreparedScanComparison?, Never>
    }
    private var comparisonBuilds: [String: ComparisonBuild] = [:]
    // One compact result, never a cache of full predecessor trees.
    private var preparedComparison: (targetID: String, snapshotID: UUID, key: ScanChangeCacheKey, value: PreparedScanComparison)?

    /// Test seam, awaited inside the detached encode: tests hold a save
    /// open with it and exercise the in-flight window deterministically.
    private var encodeGateForTesting: (@Sendable () async -> Void)?

    func setEncodeGateForTesting(_ gate: (@Sendable () async -> Void)?) {
        encodeGateForTesting = gate
    }

    public nonisolated static var defaultDirectoryURL: URL {
        // NEODISK_SNAPSHOT_DIR isolates benches from the developer's real cache.
        if let override = ProcessInfo.processInfo.environment["NEODISK_SNAPSHOT_DIR"] {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupportURL.appending(path: "\(AppChannel.current.appName)/ScanCache", directoryHint: .isDirectory)
    }

    public init(
        directoryURL: URL = ScanSnapshotCache.defaultDirectoryURL,
        isLoggingEnabled: Bool = true
    ) {
        self.directoryURL = directoryURL
        self.isLoggingEnabled = isLoggingEnabled
    }

    // MARK: - Public API

    /// Saves a complete snapshot as the latest; the prior latest rotates to "previous" unless its tree content
    /// matches, since rotating an identical tree would make every diff empty.
    @discardableResult
    public func save(_ snapshot: ScanSnapshot) async throws -> SnapshotSaveOutcome {
        guard snapshot.isComplete else {
            throw ScanSnapshotCacheError.incompleteSnapshot
        }

        let start = ContinuousClock.now
        let targetID = snapshot.target.id
        // Readable from memory while the encode runs, and the claim that
        // gates the write below.
        invalidateComparison(forTargetID: targetID)
        savingByTargetID[targetID] = snapshot
        defer {
            if savingByTargetID[targetID]?.id == snapshot.id {
                savingByTargetID.removeValue(forKey: targetID)
            }
        }
        // Off the actor so loads of other targets don't queue behind it; this target is served from
        // `savingByTargetID` meanwhile.
        let gate = encodeGateForTesting
        let (digest, data) = try await Task.detached {
            await gate?()
            try Task.checkCancellation()
            return try ScanTiming.measure("snapshot.encode", detail: "nodes=\(snapshot.treeStore.nodeCount)") {
                let digest = try ScanChangeList.contentDigest(of: snapshot.treeStore, checkCancellation: { try Task.checkCancellation() })
                try Task.checkCancellation()
                return (digest, try ScanSnapshotCodec.encode(
                    snapshot,
                    version: Self.currentFormatVersion,
                    changeDigest: digest
                ))
            }
        }.cancellableValue
        try Task.checkCancellation()
        guard savingByTargetID[targetID]?.id == snapshot.id else {
            // The slots were removed or claimed by a newer save during the encode; writing would
            // resurrect stale bytes.
            return SnapshotSaveOutcome(
                rotatedPrevious: false,
                hasPreviousSnapshot: FileManager.default.fileExists(
                    atPath: previousFileURL(forTargetID: targetID).path
                )
            )
        }
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

    /// Header-only read; files from before the digest existed never match and rotate as before.
    private func latestMatches(digest: String, targetID: String, at url: URL) -> Bool {
        guard let metadata = try? ScanSnapshotCodec.readMetadata(fromFileAt: url) else {
            return false
        }
        return metadata.targetPath == targetID && metadata.changeDigest == digest
    }

    /// Unreadable files (corruption, old versions) are deleted so they never fail twice.
    public func loadSnapshot(for target: ScanTarget) async -> ScanSnapshot? {
        // An in-flight save is fresher than any file (and the only copy on a first save).
        if let saving = savingByTargetID[target.id] {
            return saving
        }
        return await loadSnapshot(for: target, at: fileURL(forTargetID: target.id))
    }

    public func loadPreviousSnapshot(for target: ScanTarget) async -> ScanSnapshot? {
        await loadSnapshot(for: target, at: previousFileURL(forTargetID: target.id))
    }

    private func loadSnapshot(for target: ScanTarget, at url: URL) async -> ScanSnapshot? {
        let signatureAtRead = fileSignature(at: url)
        // Mapped rather than read into the heap when the volume allows it:
        // the file is only parsed once, front to back.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        let start = ContinuousClock.now
        do {
            // Decode off the actor, so a slow decode (or another target's
            // in-flight save) never queues other targets' cache traffic.
            let snapshot = try await Task.detached {
                try ScanTiming.measure("snapshot.decode", detail: "bytes=\(data.count)") {
                    try ScanSnapshotCodec.decode(data)
                }
            }.cancellableValue
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
        } catch is CancellationError {
            return nil
        } catch {
            log("discarding unreadable snapshot for \(target.id): \(error)", level: .warning)
            // The decode ran unisolated; only delete if the file is still the bytes we read.
            if let current = fileSignature(at: url),
               signatureAtRead?.size == current.size,
               signatureAtRead?.modified == current.modified {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }
    }

    /// Called once at launch: deletes entries for targets no longer in the sidebar and orphaned previous
    /// snapshots, and returns what the cache knows about the rest.
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
                log("pruning unreadable snapshot at \(url.lastPathComponent): \(error)", level: .warning)
                try? FileManager.default.removeItem(at: url)
            }
        }

        // A previous snapshot without its latest can never be diffed.
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
                hasPreviousSnapshot: previousTargetPaths.contains(path),
                totalAllocatedSize: metadata.totalAllocatedSize,
                cloudOnlyLogicalSize: metadata.cloudOnlyLogicalSize ?? 0
            )
        }
        return infoByPath
    }

    // MARK: - Auxiliary data

    /// Opaque per-target payload (e.g. kind statistics) removed and pruned with the snapshot; staleness
    /// checks are the caller's business.
    public func saveAuxiliaryData(_ data: Data, forTargetID targetID: String) {
        writeSlotData(data, to: auxiliaryFileURL(forTargetID: targetID))
    }

    public func loadAuxiliaryData(forTargetID targetID: String) -> Data? {
        try? Data(contentsOf: auxiliaryFileURL(forTargetID: targetID))
    }

    // MARK: - Cached change list (`.nddiff` slot)

    /// Identity of the latest and previous snapshot files plus the entry limit; nil when either is missing.
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

    /// Decodes the predecessor once; concurrent callers share the work and slot changes cancel obsolete builds.
    public func comparison(for snapshot: ScanSnapshot, entryLimit: Int) async -> PreparedScanComparison? {
        let targetID = snapshot.target.id
        guard snapshot.isComplete, snapshot.source.isPersistable,
              savingByTargetID[targetID] == nil,
              let metadata = try? ScanSnapshotCodec.readMetadata(fromFileAt: fileURL(forTargetID: targetID)),
              metadata.targetPath == targetID,
              abs(metadata.startedAt.timeIntervalSince(snapshot.startedAt)) < 0.000_001,
              Self.sameArchivedDate(metadata.finishedAt, snapshot.finishedAt),
              metadata.nodeCount == snapshot.treeStore.nodeCount,
              metadata.totalAllocatedSize == snapshot.aggregateStats.totalAllocatedSize,
              let key = changeListCacheKey(forTargetID: targetID, entryLimit: entryLimit) else { return nil }
        if let preparedComparison, preparedComparison.targetID == targetID,
           preparedComparison.snapshotID == snapshot.id, preparedComparison.key == key {
            return preparedComparison.value
        }
        if let build = comparisonBuilds[targetID], build.key == key, build.snapshotID == snapshot.id {
            let result = await build.task.value
            guard !Task.isCancelled, changeListCacheKey(forTargetID: targetID, entryLimit: entryLimit) == key else { return nil }
            return result
        }
        invalidateComparison(forTargetID: targetID)
        let id = UUID()
        let cachedList = loadChangeList(forTargetID: targetID, entryLimit: entryLimit)?.list
        let task = Task.detached(priority: .utility) { [self] () -> PreparedScanComparison? in
            guard let previous = await loadPreviousSnapshot(for: snapshot.target), !Task.isCancelled else { return nil }
            let baseline = ScanSizeBaseline(snapshot: previous)
            guard !Task.isCancelled else { return nil }
            let list = cachedList ?? ScanChangeList.build(
                current: snapshot.treeStore, previous: previous.treeStore, entryLimit: entryLimit
            )
            guard !Task.isCancelled else { return nil }
            return PreparedScanComparison(baseline: baseline, list: list)
        }
        comparisonBuilds[targetID] = ComparisonBuild(id: id, key: key, snapshotID: snapshot.id, task: task)
        let result = await task.value
        guard comparisonBuilds[targetID]?.id == id else { return nil }
        comparisonBuilds.removeValue(forKey: targetID)
        guard changeListCacheKey(forTargetID: targetID, entryLimit: entryLimit) == key,
              let result else { return nil }
        preparedComparison = (targetID, snapshot.id, key, result)
        saveChangeList(result.list, comparisonDate: result.baseline.finishedAt,
                       forTargetID: targetID, entryLimit: entryLimit)
        return result
    }

    // JSON seconds-since-1970 conversion can lose a fraction of a microsecond
    // relative to Date's reference epoch. Do not reject the snapshot just saved.
    private static func sameArchivedDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case let (.some(lhs), .some(rhs)): return abs(lhs.timeIntervalSince(rhs)) < 0.000_001
        default: return false
        }
    }

    private func invalidateComparison(forTargetID targetID: String) {
        comparisonBuilds.removeValue(forKey: targetID)?.task.cancel()
        if preparedComparison?.targetID == targetID { preparedComparison = nil }
    }

    /// Nil unless still valid for the current snapshot files, entry limit and diff format.
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
        writeSlotData(data, to: changeListFileURL(forTargetID: targetID))
    }

    // MARK: - Cached duplicate results (`.nddup` slot)

    /// Identity of the current snapshot file plus the scan's minimum file size; nil when it's missing.
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

    /// Nil unless still valid for the current snapshot file, minimum size and duplicate format.
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
        writeSlotData(data, to: duplicateResultsFileURL(forTargetID: targetID))
    }

    // MARK: - Cached per-file content hashes (`.ndhash`, one shared file)

    /// One shared file, not a per-target slot: entries are validated per file (size, mtime, inode), so any
    /// target's scan can reuse them. Missing or unreadable starts empty.
    public func loadDuplicateHashCache() -> DuplicateHashCache {
        guard let data = try? Data(contentsOf: duplicateHashCacheFileURL()) else {
            return DuplicateHashCache()
        }
        return DuplicateHashCache(decoding: data)
    }

    /// Persists the hash cache; a no-op when the run neither added nor
    /// freshened anything.
    public func saveDuplicateHashCache(_ cache: DuplicateHashCache) {
        guard cache.isDirty, let data = cache.encodedTrimmed() else { return }
        writeSlotData(data, to: duplicateHashCacheFileURL())
    }

    /// A failed slot write is just a cache miss on the next read, never an error.
    private func writeSlotData(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log("could not write \(url.lastPathComponent): \(error)", level: .warning)
        }
    }

    public func removeSnapshot(forTargetID targetID: String) {
        invalidateComparison(forTargetID: targetID)
        // Also invalidates any in-flight save of this target (see save()).
        savingByTargetID.removeValue(forKey: targetID)
        try? FileManager.default.removeItem(at: fileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: previousFileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: auxiliaryFileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: changeListFileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: duplicateResultsFileURL(forTargetID: targetID))
    }

    public func removeAll() {
        for build in comparisonBuilds.values { build.task.cancel() }
        comparisonBuilds.removeAll()
        preparedComparison = nil
        // Also invalidates every in-flight save (see save()).
        savingByTargetID.removeAll()
        for url in cacheFileURLs() + auxiliaryFileURLs() + changeListFileURLs() + duplicateResultsFileURLs()
            + [duplicateHashCacheFileURL()] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total size of all cache files, for the Settings privacy tab.
    public func totalSizeOnDisk() -> Int64 {
        (cacheFileURLs() + auxiliaryFileURLs() + changeListFileURLs() + duplicateResultsFileURLs()
            + [duplicateHashCacheFileURL()])
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

    private func duplicateHashCacheFileURL() -> URL {
        directoryURL.appending(path: Self.duplicateHashCacheFileName, directoryHint: .notDirectory)
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

    private func log(_ message: String, level: DiagnosticLog.Level = .info) {
        guard isLoggingEnabled else { return }
        DiagnosticLog.cache.log(level, message)
    }
}
