//
//  ScanSnapshotCache.swift
//  Neodisk
//
//  Persists the latest completed scan per location so reopening it shows the
//  previous results instantly while a background rescan refreshes them.
//
//  Each target keeps its latest scan (<hash>.ndscan) plus the one before it
//  (<hash>.prev.ndscan, rotated on save — the basis for "what grew since
//  last scan" diffs) in ~/Library/Application Support/Neodisk/ScanCache/,
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

public actor ScanSnapshotCache {
    static let currentFormatVersion: UInt32 = 2
    static let oldestReadableFormatVersion: UInt32 = 1
    private static let magic: UInt32 = 0x4E44_5343 // "NDSC"
    private static let fileExtension = "ndscan"

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
    /// slot, so the last two scans per location are always available for
    /// diffing; anything older is dropped.
    public func save(_ snapshot: ScanSnapshot) throws {
        guard snapshot.isComplete else {
            throw ScanSnapshotCacheError.incompleteSnapshot
        }

        let start = ContinuousClock.now
        let data = try ScanSnapshotCodec.encode(snapshot)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let latestURL = fileURL(forTargetID: snapshot.target.id)
        let previousURL = previousFileURL(forTargetID: snapshot.target.id)
        if FileManager.default.fileExists(atPath: latestURL.path) {
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.moveItem(at: latestURL, to: previousURL)
        }

        try data.write(to: latestURL, options: .atomic)
        log(
            "saved \(snapshot.treeStore.nodeCount) nodes (\(data.count) bytes) for "
            + "\(snapshot.target.id) in \(elapsedDescription(since: start))"
        )
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

    public func removeSnapshot(forTargetID targetID: String) {
        try? FileManager.default.removeItem(at: fileURL(forTargetID: targetID))
        try? FileManager.default.removeItem(at: previousFileURL(forTargetID: targetID))
    }

    public func removeAll() {
        for url in cacheFileURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total size of all cache files, for the Settings privacy tab.
    public func totalSizeOnDisk() -> Int64 {
        cacheFileURLs().reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total = total.addingClamped(Int64(size))
        }
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

    private func elapsedDescription(since start: ContinuousClock.Instant) -> String {
        (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))
    }

    private func log(_ message: String) {
        guard isLoggingEnabled else { return }
        FileHandle.standardError.write(Data("Neodisk ScanSnapshotCache: \(message)\n".utf8))
    }
}

// MARK: - Binary codec

/// Encodes a complete `ScanSnapshot` to a self-contained binary blob:
///
///     magic (4) · version (4) · metadata length (4) · metadata JSON
///     payload — LZFSE-compressed in version 2, raw in version 1:
///         warning count (4) · warnings
///         node records in depth-first preorder, each carrying its child count
///
/// The header and metadata JSON stay uncompressed so `readMetadata` can
/// index and prune cache files without touching the node payload. The
/// payload itself compresses ~3.5x (repeated file names, similar integers).
///
/// Storing nodes in preorder with per-node child counts makes the topology
/// implicit — no separate child map is written — and node IDs (absolute
/// paths) are derived from the parent's ID plus the node name unless they
/// differ, which keeps records compact even for million-node trees.
nonisolated enum ScanSnapshotCodec {
    struct Metadata: Codable {
        var targetPath: String
        var targetDisplayName: String
        var targetKind: String
        var startedAt: Date
        var finishedAt: Date?
        var nodeCount: Int
        var totalAllocatedSize: Int64
        var totalLogicalSize: Int64
        var fileCount: Int
        var directoryCount: Int
        var accessibleItemCount: Int
        var inaccessibleItemCount: Int
    }

    private struct NodeFlags: OptionSet {
        let rawValue: UInt16

        static let isDirectory = NodeFlags(rawValue: 1 << 0)
        static let isSymbolicLink = NodeFlags(rawValue: 1 << 1)
        static let isPackage = NodeFlags(rawValue: 1 << 2)
        static let isInaccessible = NodeFlags(rawValue: 1 << 3)
        static let selfAccessibilityDiffers = NodeFlags(rawValue: 1 << 4)
        static let isSynthetic = NodeFlags(rawValue: 1 << 5)
        static let isAutoSummarized = NodeFlags(rawValue: 1 << 6)
        static let hasExplicitID = NodeFlags(rawValue: 1 << 7)
        static let hasExplicitPath = NodeFlags(rawValue: 1 << 8)
        static let hasLastModified = NodeFlags(rawValue: 1 << 9)
        static let hasFileIdentity = NodeFlags(rawValue: 1 << 10)
        static let hasLinkCount = NodeFlags(rawValue: 1 << 11)
        static let hasUnduplicatedSize = NodeFlags(rawValue: 1 << 12)
        static let hasLogicalSize = NodeFlags(rawValue: 1 << 13)
        static let hasDescendantFileCount = NodeFlags(rawValue: 1 << 14)
    }

    private static let magic: UInt32 = 0x4E44_5343 // "NDSC"

    // MARK: Encode

    static func encode(_ snapshot: ScanSnapshot) throws -> Data {
        try encode(snapshot, version: ScanSnapshotCache.currentFormatVersion)
    }

    /// The explicit-version variant exists so tests can produce old-format
    /// files and prove they still load.
    static func encode(_ snapshot: ScanSnapshot, version: UInt32) throws -> Data {
        let store = snapshot.treeStore
        let stats = snapshot.aggregateStats
        let metadata = Metadata(
            targetPath: snapshot.target.id,
            targetDisplayName: snapshot.target.displayName,
            targetKind: snapshot.target.kind.rawValue,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            nodeCount: store.nodeCount,
            totalAllocatedSize: stats.totalAllocatedSize,
            totalLogicalSize: stats.totalLogicalSize,
            fileCount: stats.fileCount,
            directoryCount: stats.directoryCount,
            accessibleItemCount: stats.accessibleItemCount,
            inaccessibleItemCount: stats.inaccessibleItemCount
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let metadataData = try encoder.encode(metadata)

        var payload = ByteWriter()
        payload.data.reserveCapacity(64 * store.nodeCount + 64)
        payload.append(UInt32(snapshot.scanWarnings.count))
        for warning in snapshot.scanWarnings {
            payload.appendString(warning.path)
            payload.appendString(warning.message)
            payload.appendString(warning.category.rawValue)
        }

        let storage = store.storage
        for (index, node) in storage.nodes.enumerated() {
            let parentIndex = storage.parentIndices[index]
            let parentID = parentIndex >= 0 ? storage.nodes[Int(parentIndex)].id : nil
            appendNode(
                node,
                parentID: parentID,
                childCount: storage.childCount(of: Int32(index)),
                to: &payload
            )
        }

        var writer = ByteWriter()
        writer.append(magic)
        writer.append(version)
        writer.append(UInt32(metadataData.count))
        writer.data.append(metadataData)
        if version >= 2 {
            writer.data.append(try (payload.data as NSData).compressed(using: .lzfse) as Data)
        } else {
            writer.data.append(payload.data)
        }
        return writer.data
    }

    private static func appendNode(
        _ node: FileNodeRecord,
        parentID: String?,
        childCount: Int,
        to writer: inout ByteWriter
    ) {
        let derivedID = parentID.map { joinedChildID(parentID: $0, name: node.name) }
        let path = node.path
        let defaultDescendantFileCount = node.isDirectory ? 0 : 1

        var flags: NodeFlags = []
        if node.isDirectory { flags.insert(.isDirectory) }
        if node.isSymbolicLink { flags.insert(.isSymbolicLink) }
        if node.isPackage { flags.insert(.isPackage) }
        if !node.isAccessible { flags.insert(.isInaccessible) }
        if node.isSelfAccessible != node.isAccessible { flags.insert(.selfAccessibilityDiffers) }
        if node.isSynthetic { flags.insert(.isSynthetic) }
        if node.isAutoSummarized { flags.insert(.isAutoSummarized) }
        if node.id != derivedID { flags.insert(.hasExplicitID) }
        if path != node.id { flags.insert(.hasExplicitPath) }
        if node.lastModified != nil { flags.insert(.hasLastModified) }
        if node.fileIdentity != nil { flags.insert(.hasFileIdentity) }
        if node.linkCount != 1 { flags.insert(.hasLinkCount) }
        if node.unduplicatedAllocatedSize != node.allocatedSize { flags.insert(.hasUnduplicatedSize) }
        if node.logicalSize != node.allocatedSize { flags.insert(.hasLogicalSize) }
        if node.descendantFileCount != defaultDescendantFileCount { flags.insert(.hasDescendantFileCount) }

        writer.append(flags.rawValue)
        writer.appendString(node.name)
        if flags.contains(.hasExplicitID) { writer.appendString(node.id) }
        if flags.contains(.hasExplicitPath) { writer.appendString(path) }
        writer.append(node.allocatedSize)
        if flags.contains(.hasUnduplicatedSize) { writer.append(node.unduplicatedAllocatedSize) }
        if flags.contains(.hasLogicalSize) { writer.append(node.logicalSize) }
        if flags.contains(.hasDescendantFileCount) { writer.append(Int64(node.descendantFileCount)) }
        if let lastModified = node.lastModified {
            writer.append(lastModified.timeIntervalSinceReferenceDate)
        }
        if let identity = node.fileIdentity {
            switch identity {
            case .resourceIdentifier(let data):
                writer.append(UInt8(0))
                writer.append(UInt32(data.count))
                writer.data.append(data)
            case .fileSystem(let device, let inode):
                writer.append(UInt8(1))
                writer.append(device)
                writer.append(inode)
            }
        }
        if flags.contains(.hasLinkCount) { writer.append(node.linkCount) }
        writer.append(UInt32(childCount))
    }

    // MARK: Decode

    static func decode(_ data: Data) throws -> ScanSnapshot {
        var headerReader = ByteReader(data: data)
        let (version, metadataLength) = try validatedHeader(from: &headerReader)
        let metadata = try decodeMetadata(try headerReader.readBytes(count: metadataLength))

        let payload: Data
        if version >= 2 {
            let compressed = try headerReader.readBytes(count: headerReader.remainingByteCount)
            guard let decompressed = try? (compressed as NSData).decompressed(using: .lzfse) as Data else {
                throw ScanSnapshotCacheError.corruptData("payload decompression failed")
            }
            payload = decompressed
        } else {
            payload = try headerReader.readBytes(count: headerReader.remainingByteCount)
        }

        let stats = ScanAggregateStats(
            totalAllocatedSize: metadata.totalAllocatedSize,
            totalLogicalSize: metadata.totalLogicalSize,
            fileCount: metadata.fileCount,
            directoryCount: metadata.directoryCount,
            accessibleItemCount: metadata.accessibleItemCount,
            inaccessibleItemCount: metadata.inaccessibleItemCount
        )

        // The payload is decoded through raw-pointer reads: per-node Data
        // subscripting and subdata copies were a measurable share of loading
        // a millions-of-nodes snapshot.
        let (warnings, store) = try payload.withUnsafeBytes { bytes in
            var reader = PayloadReader(buffer: bytes)

            let warningCount = Int(try reader.readUInt32())
            guard warningCount <= bytes.count else {
                throw ScanSnapshotCacheError.corruptData("implausible warning count \(warningCount)")
            }
            var warnings: [ScanWarning] = []
            warnings.reserveCapacity(warningCount)
            for _ in 0..<warningCount {
                let path = try reader.readString()
                let message = try reader.readString()
                let categoryRaw = try reader.readString()
                guard let category = ScanWarningCategory(rawValue: categoryRaw) else {
                    throw ScanSnapshotCacheError.corruptData("unknown warning category \(categoryRaw)")
                }
                warnings.append(ScanWarning(path: path, message: message, category: category))
            }

            let store = try readTreeStore(
                nodeCount: metadata.nodeCount,
                aggregateStats: stats,
                from: &reader
            )
            guard reader.isAtEnd else {
                throw ScanSnapshotCacheError.corruptData("trailing bytes after node records")
            }
            return (warnings, store)
        }
        guard store.nodeCount == metadata.nodeCount else {
            throw ScanSnapshotCacheError.corruptData(
                "tree store kept \(store.nodeCount) of \(metadata.nodeCount) nodes"
            )
        }

        guard let kind = ScanTargetKind(rawValue: metadata.targetKind) else {
            throw ScanSnapshotCacheError.corruptData("unknown target kind \(metadata.targetKind)")
        }
        let target = ScanTarget(
            id: metadata.targetPath,
            url: URL(filePath: metadata.targetPath, directoryHint: .isDirectory),
            displayName: metadata.targetDisplayName,
            kind: kind
        )

        return ScanSnapshot(
            target: target,
            treeStore: store,
            startedAt: metadata.startedAt,
            finishedAt: metadata.finishedAt,
            scanWarnings: warnings,
            aggregateStats: stats,
            isComplete: true
        )
    }

    /// Reads just the header of a cache file — enough for pruning and
    /// last-scan indexing without decoding the node payload.
    static func readMetadata(fromFileAt url: URL) throws -> Metadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let prefix = try handle.read(upToCount: 12), prefix.count == 12 else {
            throw ScanSnapshotCacheError.corruptData("file shorter than header")
        }
        var reader = ByteReader(data: prefix)
        let (_, metadataLength) = try validatedHeader(from: &reader)
        guard let metadataData = try handle.read(upToCount: metadataLength),
              metadataData.count == metadataLength else {
            throw ScanSnapshotCacheError.corruptData("truncated metadata block")
        }
        return try decodeMetadata(metadataData)
    }

    private static func validatedHeader(
        from reader: inout ByteReader
    ) throws -> (version: UInt32, metadataLength: Int) {
        guard try reader.readUInt32() == magic else {
            throw ScanSnapshotCacheError.unsupportedFormat
        }
        let version = try reader.readUInt32()
        guard version >= ScanSnapshotCache.oldestReadableFormatVersion,
              version <= ScanSnapshotCache.currentFormatVersion else {
            throw ScanSnapshotCacheError.unsupportedVersion(version)
        }
        let metadataLength = Int(try reader.readUInt32())
        guard metadataLength > 0, metadataLength <= 1024 * 1024 else {
            throw ScanSnapshotCacheError.corruptData("implausible metadata length \(metadataLength)")
        }
        return (version, metadataLength)
    }

    private static func decodeMetadata(_ data: Data) throws -> Metadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            let metadata = try decoder.decode(Metadata.self, from: data)
            guard metadata.nodeCount > 0 else {
                throw ScanSnapshotCacheError.corruptData("snapshot has no nodes")
            }
            return metadata
        } catch let error as ScanSnapshotCacheError {
            throw error
        } catch {
            throw ScanSnapshotCacheError.corruptData("metadata JSON: \(error.localizedDescription)")
        }
    }

    private static func readTreeStore(
        nodeCount: Int,
        aggregateStats: ScanAggregateStats,
        from reader: inout PayloadReader
    ) throws -> FileTreeStore {
        guard nodeCount <= reader.remainingByteCount else {
            throw ScanSnapshotCacheError.corruptData("implausible node count \(nodeCount)")
        }

        // Records arrive in preorder with per-node child counts, which is
        // exactly the contiguous TreeStorage layout — decode fills the
        // arrays directly. The id → index map is built afterwards in one
        // parallel pass (NodeIDIndex.building), which also detects
        // duplicate IDs; keeping it out of this loop roughly halves decode.
        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        var childStarts: [Int32] = [0]
        var childSlots = [Int32](repeating: 0, count: max(0, nodeCount - 1))
        nodes.reserveCapacity(nodeCount)
        parentIndices.reserveCapacity(nodeCount)
        childStarts.reserveCapacity(nodeCount + 1)
        /// Ancestors whose child ranges are still being filled: how many
        /// direct children each still expects, and the next free slot in
        /// the range.
        var openDirectories: [(index: Int32, remainingChildren: Int, nextSlot: Int)] = []

        for _ in 0..<nodeCount {
            let parentID = openDirectories.last.map { nodes[Int($0.index)].id }
            let (node, childCount) = try readNode(parentID: parentID, from: &reader)
            let index = Int32(nodes.count)

            if let openIndex = openDirectories.indices.last {
                openDirectories[openIndex].remainingChildren -= 1
                let slot = openDirectories[openIndex].nextSlot
                guard slot < childSlots.count else {
                    throw ScanSnapshotCacheError.corruptData("child counts exceed node count")
                }
                childSlots[slot] = index
                openDirectories[openIndex].nextSlot = slot + 1
                parentIndices.append(openDirectories[openIndex].index)
            } else if nodes.isEmpty {
                parentIndices.append(-1)
            } else {
                throw ScanSnapshotCacheError.corruptData("multiple roots in node records")
            }
            nodes.append(node)
            childStarts.append(childStarts[Int(index)] + Int32(childCount))

            if childCount > 0 {
                guard node.isDirectory else {
                    throw ScanSnapshotCacheError.corruptData("non-directory \(node.id) has children")
                }
                openDirectories.append((
                    index: index,
                    remainingChildren: childCount,
                    nextSlot: Int(childStarts[Int(index)])
                ))
            } else {
                while let last = openDirectories.last, last.remainingChildren == 0 {
                    openDirectories.removeLast()
                }
            }
        }

        guard openDirectories.isEmpty else {
            throw ScanSnapshotCacheError.corruptData("node records ended with unfinished directories")
        }
        guard let rootNode = nodes.first else {
            throw ScanSnapshotCacheError.corruptData("no root node")
        }
        guard let indexByID = NodeIDIndex.building(from: nodes) else {
            throw ScanSnapshotCacheError.corruptData("duplicate node IDs")
        }

        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: parentIndices,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: indexByID
            ),
            rootID: rootNode.id,
            aggregateStats: aggregateStats
        )
    }

    private static func readNode(
        parentID: String?,
        from reader: inout PayloadReader
    ) throws -> (node: FileNodeRecord, childCount: Int) {
        let flags = NodeFlags(rawValue: try reader.readUInt16())
        let name = try reader.readString()
        let isDirectory = flags.contains(.isDirectory)

        let id: String
        if flags.contains(.hasExplicitID) {
            id = try reader.readString()
        } else if let parentID {
            id = joinedChildID(parentID: parentID, name: name)
        } else {
            throw ScanSnapshotCacheError.corruptData("root node without explicit ID")
        }
        guard !id.isEmpty else {
            throw ScanSnapshotCacheError.corruptData("node has empty ID")
        }

        let path = flags.contains(.hasExplicitPath) ? try reader.readString() : id
        let allocatedSize = try reader.readInt64()
        let unduplicatedSize = flags.contains(.hasUnduplicatedSize) ? try reader.readInt64() : allocatedSize
        let logicalSize = flags.contains(.hasLogicalSize) ? try reader.readInt64() : allocatedSize
        let descendantFileCount = flags.contains(.hasDescendantFileCount)
            ? Int(try reader.readInt64())
            : (isDirectory ? 0 : 1)
        guard allocatedSize >= 0, unduplicatedSize >= 0, logicalSize >= 0, descendantFileCount >= 0 else {
            throw ScanSnapshotCacheError.corruptData("node \(id) has negative size or count")
        }

        var lastModified: Date?
        if flags.contains(.hasLastModified) {
            lastModified = Date(timeIntervalSinceReferenceDate: try reader.readDouble())
        }

        var fileIdentity: FileIdentity?
        if flags.contains(.hasFileIdentity) {
            switch try reader.readUInt8() {
            case 0:
                let length = Int(try reader.readUInt32())
                fileIdentity = .resourceIdentifier(try reader.readBytes(count: length))
            case 1:
                fileIdentity = .fileSystem(device: try reader.readUInt64(), inode: try reader.readUInt64())
            case let kind:
                throw ScanSnapshotCacheError.corruptData("unknown file identity kind \(kind)")
            }
        }

        let linkCount = flags.contains(.hasLinkCount) ? try reader.readUInt64() : 1
        let childCount = Int(try reader.readUInt32())
        guard childCount <= reader.remainingByteCount else {
            throw ScanSnapshotCacheError.corruptData("implausible child count \(childCount) for \(id)")
        }

        let isAccessible = !flags.contains(.isInaccessible)
        let node = FileNodeRecord(
            id: id,
            path: path,
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: flags.contains(.isSymbolicLink),
            allocatedSize: allocatedSize,
            unduplicatedAllocatedSize: unduplicatedSize,
            logicalSize: logicalSize,
            descendantFileCount: descendantFileCount,
            lastModified: lastModified,
            fileIdentity: fileIdentity,
            linkCount: max(linkCount, 1),
            isPackage: flags.contains(.isPackage),
            isAccessible: isAccessible,
            isSelfAccessible: flags.contains(.selfAccessibilityDiffers) ? !isAccessible : isAccessible,
            isSynthetic: flags.contains(.isSynthetic),
            isAutoSummarized: flags.contains(.isAutoSummarized)
        )
        return (node, childCount)
    }

    /// One-allocation join of parent path and child name — the plain `+`
    /// concatenation showed up in decode profiles at millions of nodes.
    private static func joinedChildID(parentID: String, name: String) -> String {
        var parentID = parentID
        var name = name
        return parentID.withUTF8 { parentBytes in
            name.withUTF8 { nameBytes in
                let parentCount = parentBytes.count == 1 && parentBytes[0] == UInt8(ascii: "/")
                    ? 0
                    : parentBytes.count
                let total = parentCount + 1 + nameBytes.count
                return String(unsafeUninitializedCapacity: total) { output in
                    if parentCount > 0 {
                        _ = output.initialize(fromContentsOf: parentBytes)
                    }
                    output[parentCount] = UInt8(ascii: "/")
                    _ = UnsafeMutableBufferPointer(
                        rebasing: output[(parentCount + 1)...]
                    ).initialize(fromContentsOf: nameBytes)
                    return total
                }
            }
        }
    }
}

/// Raw-pointer counterpart of ByteReader for the (possibly decompressed)
/// node payload: no per-read Data subscripting, and strings decode straight
/// from the buffer. Only valid inside the payload's withUnsafeBytes scope.
private nonisolated struct PayloadReader {
    let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var isAtEnd: Bool {
        offset == buffer.count
    }

    var remainingByteCount: Int {
        buffer.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingByteCount >= 1 else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(littleEndian: try load(UInt16.self))
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(littleEndian: try load(UInt32.self))
    }

    mutating func readUInt64() throws -> UInt64 {
        UInt64(littleEndian: try load(UInt64.self))
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt32())
        guard remainingByteCount >= count else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += count }
        return String(
            decoding: UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + count)]),
            as: UTF8.self
        )
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, remainingByteCount >= count else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += count }
        return Data(buffer[offset..<(offset + count)])
    }

    private mutating func load<T>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingByteCount >= size else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += size }
        return buffer.loadUnaligned(fromByteOffset: offset, as: type)
    }
}

// MARK: - Little-endian byte buffers

private nonisolated struct ByteWriter {
    var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt32(bytes.count))
        data.append(bytes)
    }
}

private nonisolated struct ByteReader {
    let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingByteCount >= 1 else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(littleEndian: try load(UInt16.self))
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(littleEndian: try load(UInt32.self))
    }

    mutating func readUInt64() throws -> UInt64 {
        UInt64(littleEndian: try load(UInt64.self))
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let bytes = try readBytes(count: length)
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, remainingByteCount >= count else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        let start = data.startIndex + offset
        defer { offset += count }
        return data.subdata(in: start..<(start + count))
    }

    private mutating func load<T>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingByteCount >= size else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        // withUnsafeBytes rebases the buffer to index 0 regardless of the
        // Data's startIndex, so the plain running offset is the right one.
        defer { offset += size }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: type)
        }
    }
}
