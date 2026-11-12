// Binary snapshot format behind ScanSnapshotCache, plus the header-only metadata read for indexing.

import Dispatch
import Foundation

/// Layout: magic, version, metadata length, uncompressed metadata JSON, then a payload (compressed in v2+)
/// of warnings and preorder node records with child counts, so topology is implicit and IDs derive from parents.
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
        /// Lets a save tell an unchanged rescan from a real change without decoding the old payload. Older
        /// files decode as nil and never match.
        var changeDigest: String?
        /// Readable without decoding the payload (sidebar cloud bar). Omitted when zero; older files decode as
        /// nil.
        var cloudOnlyLogicalSize: Int64?
        /// FSEvents position from scan start, the basis for the next incremental rescan. Nil (older files)
        /// falls back to a full scan.
        var incrementalCheckpoint: FSEventsCheckpoint?
        /// Lets a rescan verify the options are unchanged. Older files decode as nil.
        var scanOptions: ScanOptions?
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
        /// v3+, last free bit, meaning split by type: a dataless file, or on a directory a trailing
        /// cloudOnlyLogicalSize Int64.
        static let cloudOnly = NodeFlags(rawValue: 1 << 15)
    }

    /// v4+: a second flags byte after the fixed fields — the UInt16 above is
    /// full. Gates the optional trailing payloads added since v3.
    private struct NodeExtraFlags: OptionSet {
        let rawValue: UInt8

        /// Trailing clone-family payload: device u64 · cloneID u64 ·
        /// refCount u32 · privateSize i64 (−1 when unknown).
        static let hasCloneInfo = NodeExtraFlags(rawValue: 1 << 0)
        /// v5+: count u32, then per family device u64, cloneID u64, memberCount u32, totalSize, largestSize,
        /// charge (i64 each).
        static let hasSummarizedClones = NodeExtraFlags(rawValue: 1 << 1)
    }

    private static let magic: UInt32 = 0x4E44_5343 // "NDSC"

    // MARK: Encode

    static func encode(_ snapshot: ScanSnapshot) throws -> Data {
        try encode(snapshot, version: ScanSnapshotCache.currentFormatVersion)
    }

    /// The explicit version lets tests write old-format files. `changeDigest` is computed here if not passed.
    static func encode(
        _ snapshot: ScanSnapshot,
        version: UInt32,
        changeDigest: String? = nil
    ) throws -> Data {
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
            inaccessibleItemCount: stats.inaccessibleItemCount,
            changeDigest: try changeDigest ?? ScanChangeList.contentDigest(of: store, checkCancellation: Task.checkCancellation),
            cloudOnlyLogicalSize: (store.storage.nodes.first?.cloudOnlyLogicalSize).flatMap {
                $0 > 0 ? $0 : nil
            },
            incrementalCheckpoint: snapshot.incrementalCheckpoint,
            scanOptions: snapshot.scanOptions
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

        // Display preorder, not array order: the decoder rebuilds children in stream order, and an in-place
        // rebuild may have re-sorted child slots without moving records.
        let storage = store.storage
        var visited = 0
        try storage.forEachIndexInDisplayPreorder { index in
            if visited & 1023 == 0 { try Task.checkCancellation() }
            visited += 1
            let parentIndex = storage.parentIndices[Int(index)]
            let parentID = parentIndex >= 0 ? storage.nodes[Int(parentIndex)].id : nil
            appendNode(
                storage.nodes[Int(index)],
                parentID: parentID,
                childCount: storage.childCount(of: index),
                version: version,
                to: &payload
            )
        }

        guard payload.data.count <= 2 * 1024 * 1024 * 1024 else {
            throw ScanSnapshotCacheError.corruptData("snapshot payload exceeds supported size")
        }
        try Task.checkCancellation()
        var writer = ByteWriter()
        writer.append(magic)
        writer.append(version)
        writer.append(UInt32(metadataData.count))
        writer.data.append(metadataData)
        if version >= 2 {
            try appendCompressedPayload(payload.data, to: &writer.data)
        } else {
            writer.data.append(payload.data)
        }
        return writer.data
    }

    private static func appendNode(
        _ node: FileNodeRecord,
        parentID: String?,
        childCount: Int,
        version: UInt32,
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
        if version >= 3 {
            if node.isDirectory {
                if node.cloudOnlyLogicalSize > 0 { flags.insert(.cloudOnly) }
            } else if node.isDataless {
                flags.insert(.cloudOnly)
            }
        }

        writer.append(flags.rawValue)
        writer.appendString(node.name)
        if flags.contains(.hasExplicitID) { writer.appendString(node.id) }
        if flags.contains(.hasExplicitPath) { writer.appendString(path) }
        writer.append(node.allocatedSize)
        if flags.contains(.hasUnduplicatedSize) { writer.append(node.unduplicatedAllocatedSize) }
        if flags.contains(.hasLogicalSize) { writer.append(node.logicalSize) }
        // Files carry no cloud payload — their cloudOnlyLogicalSize derives
        // from the flag and logicalSize on decode.
        if flags.contains(.cloudOnly), node.isDirectory { writer.append(node.cloudOnlyLogicalSize) }
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
        if version >= 4 {
            var extraFlags: NodeExtraFlags = []
            if node.cloneInfo != nil { extraFlags.insert(.hasCloneInfo) }
            let summarizedClones = version >= 5 ? node.summarizedClones : nil
            if summarizedClones != nil { extraFlags.insert(.hasSummarizedClones) }
            writer.append(extraFlags.rawValue)
            if let cloneInfo = node.cloneInfo {
                writer.append(cloneInfo.device)
                writer.append(cloneInfo.cloneID)
                writer.append(cloneInfo.refCount)
                writer.append(cloneInfo.privateSize ?? -1)
            }
            if let summarizedClones {
                writer.append(UInt32(summarizedClones.families.count))
                for family in summarizedClones.families {
                    writer.append(family.familyKey.device)
                    writer.append(family.familyKey.cloneID)
                    writer.append(family.memberCount)
                    writer.append(family.totalSize)
                    writer.append(family.largestSize)
                    writer.append(family.charge)
                }
            }
        }
        writer.append(UInt32(childCount))
    }

    // MARK: Decode

    static func decode(_ data: Data) throws -> ScanSnapshot {
        var headerReader = ByteReader(data: data)
        let (version, metadataLength) = try validatedHeader(from: &headerReader)
        let metadata = try decodeMetadata(try headerReader.readBytes(count: metadataLength))

        let stats = ScanAggregateStats(
            totalAllocatedSize: metadata.totalAllocatedSize,
            totalLogicalSize: metadata.totalLogicalSize,
            fileCount: metadata.fileCount,
            directoryCount: metadata.directoryCount,
            accessibleItemCount: metadata.accessibleItemCount,
            inaccessibleItemCount: metadata.inaccessibleItemCount
        )

        let warnings: [ScanWarning]
        let store: FileTreeStore
        if version >= 2 {
            // Parsed as it decompresses: the whole payload (hundreds of MB
            // for millions of nodes) never sits in memory beside the tree.
            let compressed = headerReader.readSlice(count: headerReader.remainingByteCount)
            let decompressor = try PayloadDecompressor(compressed: compressed)
            var reader = StreamingPayloadReader(source: PrefetchingPayloadSource(source: decompressor))
            (warnings, store) = try decodePayload(from: &reader, metadata: metadata, stats: stats, version: version)
            ScanTiming.record("snapshot.decode.decompress", .nanoseconds(Int64(decompressor.decompressNanoseconds)))
        } else {
            // Raw-pointer reads: per-node Data subscripting was a measurable share of loading big snapshots.
            let payload = headerReader.readSlice(count: headerReader.remainingByteCount)
            (warnings, store) = try payload.withUnsafeBytes { bytes in
                var reader = PayloadReader(buffer: bytes)
                return try decodePayload(from: &reader, metadata: metadata, stats: stats, version: version)
            }
        }
        guard store.nodeCount == metadata.nodeCount else {
            throw ScanSnapshotCacheError.corruptData(
                "tree store kept \(store.nodeCount) of \(metadata.nodeCount) nodes"
            )
        }

        guard let kind = ScanTargetKind(rawValue: metadata.targetKind) else {
            throw ScanSnapshotCacheError.corruptData("unknown target kind \(metadata.targetKind)")
        }
        let targetURL = URL(filePath: metadata.targetPath, directoryHint: .isDirectory)
        let target = ScanTarget(
            id: metadata.targetPath,
            url: targetURL,
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
            isComplete: true,
            scanOptions: metadata.scanOptions,
            incrementalCheckpoint: trustsCheckpoint(version: version, targetPath: metadata.targetPath)
                ? metadata.incrementalCheckpoint : nil
        )
    }

    /// A dropped checkpoint forces one full rescan. Before v5 packages counted inner clones at full size;
    /// before v6 rescans of other volumes replayed no changes, so their trees can still hold deleted files.
    private static func trustsCheckpoint(version: UInt32, targetPath: String) -> Bool {
        version >= 6 || (version == 5 && !targetPath.hasPrefix("/Volumes/"))
    }

    private static func decodePayload<Reader: PayloadReading>(
        from reader: inout Reader,
        metadata: Metadata,
        stats: ScanAggregateStats,
        version: UInt32
    ) throws -> (warnings: [ScanWarning], store: FileTreeStore) {
        let warningCount = Int(try reader.readUInt32())
        guard warningCount <= reader.remainingByteCount / 12 else {
            throw ScanSnapshotCacheError.corruptData("implausible warning count \(warningCount)")
        }
        var warnings: [ScanWarning] = []
        warnings.reserveCapacity(min(warningCount, 1 << 16))
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
            version: version,
            from: &reader
        )
        guard reader.isAtEnd else {
            throw ScanSnapshotCacheError.corruptData("trailing bytes after node records")
        }
        return (warnings, store)
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
            guard metadata.nodeCount > 0, metadata.nodeCount < Int(Int32.max),
                  metadata.totalAllocatedSize >= 0, metadata.totalLogicalSize >= 0,
                  metadata.fileCount >= 0, metadata.directoryCount >= 0,
                  metadata.accessibleItemCount >= 0, metadata.inaccessibleItemCount >= 0,
                  metadata.cloudOnlyLogicalSize ?? 0 >= 0 else {
                throw ScanSnapshotCacheError.corruptData("invalid snapshot size or count")
            }
            return metadata
        } catch let error as ScanSnapshotCacheError {
            throw error
        } catch {
            throw ScanSnapshotCacheError.corruptData("metadata JSON: \(error.localizedDescription)")
        }
    }

    /// Nodes per batch handed to a worker: big enough that dispatch is noise, small enough to keep cores fed.
    private static let decodeBatchSize = 8192

    private static func readTreeStore<Reader: PayloadReading>(
        nodeCount: Int,
        aggregateStats: ScanAggregateStats,
        version: UInt32,
        from reader: inout Reader
    ) throws -> FileTreeStore {
        // Even an empty-name record needs flags, a string length, size,
        // child count, and (v4+) extended flags. Reject before reserving arrays.
        let minimumNodeBytes = version >= 4 ? 19 : 18
        guard nodeCount <= reader.remainingByteCount / minimumNodeBytes else {
            throw ScanSnapshotCacheError.corruptData("implausible node count \(nodeCount)")
        }

        // Preorder with child counts is exactly the TreeStorage layout. This thread parses the stream in order
        // (fields, topology, each node's id and name bytes); workers turn batches into records and id hashes,
        // since building millions of strings was most of a big decode.
        var parentIndices: [Int32] = []
        var childStarts: [Int32] = [0]
        var childSlots = [Int32](repeating: 0, count: max(0, nodeCount - 1))
        parentIndices.reserveCapacity(nodeCount)
        childStarts.reserveCapacity(nodeCount + 1)
        /// Ancestors still being filled: children each still expects, the next free slot, and where its id
        /// ends in `ancestorIDBytes`.
        var openDirectories: [(index: Int32, remainingChildren: Int, nextSlot: Int, idEnd: Int)] = []
        /// The open directories' ids, back to back: a child's id is the last one, a slash and its name.
        var ancestorIDBytes: [UInt8] = []
        var hashes = [UInt64](repeating: 0, count: nodeCount)
        var rootID: String?

        let nodes = try hashes.withUnsafeMutableBufferPointer { hashesOut in
            try [FileNodeRecord](unsafeUninitializedCapacity: nodeCount) { buffer, initializedCount in
                nonisolated(unsafe) let records = buffer
                nonisolated(unsafe) let hashesBuffer = hashesOut
                let group = DispatchGroup()
                // Bounds the batches parsed ahead of the workers, and so the arenas held at once.
                let inFlight = DispatchSemaphore(value: ProcessInfo.processInfo.activeProcessorCount)
                let queue = DispatchQueue.global(qos: .userInitiated)
                var dispatchedCount = 0
                var batch = PendingBatch(firstIndex: 0, capacity: decodeBatchSize)

                func dispatch() {
                    let sent = batch
                    dispatchedCount += sent.nodes.count
                    batch = PendingBatch(firstIndex: dispatchedCount, capacity: decodeBatchSize)
                    inFlight.wait()
                    queue.async(group: group) {
                        sent.materialize(into: records, hashes: hashesBuffer)
                        inFlight.signal()
                    }
                }

                do {
                    for index in 0..<nodeCount {
                        if index & 1023 == 0 { try Task.checkCancellation() }
                        let parentIDBytes = openDirectories.last.map { last in
                            ancestorIDBytes[(openDirectories.dropLast().last?.idEnd ?? 0)..<last.idEnd]
                        }
                        let (pending, childCount) = try readPendingNode(
                            parentIDBytes: parentIDBytes,
                            version: version,
                            arena: &batch.bytes,
                            from: &reader
                        )
                        let index = Int32(index)

                        if let openIndex = openDirectories.indices.last {
                            openDirectories[openIndex].remainingChildren -= 1
                            let slot = openDirectories[openIndex].nextSlot
                            guard slot < childSlots.count else {
                                throw ScanSnapshotCacheError.corruptData("child counts exceed node count")
                            }
                            childSlots[slot] = index
                            openDirectories[openIndex].nextSlot = slot + 1
                            parentIndices.append(openDirectories[openIndex].index)
                        } else if index == 0 {
                            parentIndices.append(-1)
                            rootID = batch.string(at: pending.id)
                        } else {
                            throw ScanSnapshotCacheError.corruptData("multiple roots in node records")
                        }
                        guard childCount <= childSlots.count - Int(childStarts[Int(index)]) else {
                            throw ScanSnapshotCacheError.corruptData("child counts exceed node count")
                        }
                        childStarts.append(childStarts[Int(index)] + Int32(childCount))

                        if childCount > 0 {
                            guard pending.isDirectory else {
                                throw ScanSnapshotCacheError.corruptData(
                                    "non-directory \(batch.string(at: pending.id)) has children"
                                )
                            }
                            ancestorIDBytes.append(contentsOf: batch.bytes[pending.id])
                            openDirectories.append((
                                index: index,
                                remainingChildren: childCount,
                                nextSlot: Int(childStarts[Int(index)]),
                                idEnd: ancestorIDBytes.count
                            ))
                        }
                        batch.nodes.append(pending)
                        if childCount == 0 {
                            while let last = openDirectories.last, last.remainingChildren == 0 {
                                openDirectories.removeLast()
                                ancestorIDBytes.removeSubrange((openDirectories.last?.idEnd ?? 0)...)
                            }
                        }
                        if batch.nodes.count == decodeBatchSize { dispatch() }
                    }
                    if !batch.nodes.isEmpty { dispatch() }
                } catch {
                    // Batches fill in index order, so everything handed to a worker is the initialized prefix.
                    group.wait()
                    initializedCount = dispatchedCount
                    throw error
                }
                group.wait()
                initializedCount = nodeCount
            }
        }

        guard openDirectories.isEmpty else {
            throw ScanSnapshotCacheError.corruptData("node records ended with unfinished directories")
        }
        guard let rootID else {
            throw ScanSnapshotCacheError.corruptData("no root node")
        }
        guard let built = NodeIDIndex.building(from: nodes, hashes: hashes) else {
            throw ScanSnapshotCacheError.corruptData("duplicate node IDs")
        }
        // Older files stored some siblings in stale pre-dedup order; a no-op on files written since.
        TreeStorage.restoreChildDisplayOrder(
            nodes: nodes,
            childStarts: childStarts,
            childSlots: &childSlots
        )

        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: parentIndices,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: built.index,
                nodeHashes: built.hashes
            ),
            rootID: rootID,
            aggregateStats: aggregateStats
        )
    }

    /// A node read from the stream, its strings still bytes in its batch's arena.
    private struct PendingNode {
        var id: Range<Int>
        var name: Range<Int>
        /// Nil when the path is the id.
        var path: Range<Int>?
        var isDirectory: Bool
        var isSymbolicLink: Bool
        var isPackage: Bool
        var isAccessible: Bool
        var isSelfAccessible: Bool
        var isSynthetic: Bool
        var isAutoSummarized: Bool
        var isDataless: Bool
        var allocatedSize: Int64
        var unduplicatedSize: Int64
        var logicalSize: Int64
        var cloudOnlyLogicalSize: Int64?
        var descendantFileCount: Int
        /// NaN when absent: a Date? costs resilient copies per node.
        var modifiedSeconds: Double
        var fileIdentity: FileIdentity?
        var linkCount: UInt64
        var cloneInfo: CloneInfo?
        var summarizedClones: SummarizedClones?
    }

    /// Consecutive nodes from `firstIndex` and the bytes of their strings.
    private struct PendingBatch: @unchecked Sendable {
        let firstIndex: Int
        var nodes: [PendingNode] = []
        var bytes: [UInt8] = []

        init(firstIndex: Int, capacity: Int) {
            self.firstIndex = firstIndex
            nodes.reserveCapacity(capacity)
            bytes.reserveCapacity(capacity * 96)
        }

        func string(at range: Range<Int>) -> String {
            bytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[range]), as: UTF8.self) }
        }

        /// Initializes this batch's slots of `records` and `hashes`; batches never share a slot.
        func materialize(
            into records: UnsafeMutableBufferPointer<FileNodeRecord>,
            hashes: UnsafeMutableBufferPointer<UInt64>
        ) {
            for (offset, node) in nodes.enumerated() {
                let id = string(at: node.id)
                let index = firstIndex + offset
                hashes[index] = FNV1a.hash(id)
                (records.baseAddress! + index).initialize(to: FileNodeRecord(
                    id: id,
                    path: node.path.map(string(at:)) ?? id,
                    name: string(at: node.name),
                    isDirectory: node.isDirectory,
                    isSymbolicLink: node.isSymbolicLink,
                    allocatedSize: node.allocatedSize,
                    unduplicatedAllocatedSize: node.unduplicatedSize,
                    logicalSize: node.logicalSize,
                    descendantFileCount: node.descendantFileCount,
                    lastModified: node.modifiedSeconds.isNaN
                        ? nil
                        : Date(timeIntervalSinceReferenceDate: node.modifiedSeconds),
                    fileIdentity: node.fileIdentity,
                    linkCount: node.linkCount,
                    isPackage: node.isPackage,
                    isAccessible: node.isAccessible,
                    isSelfAccessible: node.isSelfAccessible,
                    isSynthetic: node.isSynthetic,
                    isAutoSummarized: node.isAutoSummarized,
                    isDataless: node.isDataless,
                    cloudOnlyLogicalSize: node.cloudOnlyLogicalSize,
                    cloneInfo: node.cloneInfo,
                    summarizedClones: node.summarizedClones
                ))
            }
        }
    }

    /// Reads one record, appending its id, name and explicit path bytes to `arena`. A derived id is the
    /// parent's id bytes, a slash and the name (the root's children skip the root's own slash).
    private static func readPendingNode<Reader: PayloadReading>(
        parentIDBytes: ArraySlice<UInt8>?,
        version: UInt32,
        arena: inout [UInt8],
        from reader: inout Reader
    ) throws -> (node: PendingNode, childCount: Int) {
        let flags = NodeFlags(rawValue: try reader.readUInt16())
        let nameStart = arena.count
        try reader.readStringBytes(appendingTo: &arena)
        let name = nameStart..<arena.count
        let isDirectory = flags.contains(.isDirectory)

        let id: Range<Int>
        let idStart = arena.count
        if flags.contains(.hasExplicitID) {
            try reader.readStringBytes(appendingTo: &arena)
        } else if let parentIDBytes {
            if !(parentIDBytes.count == 1 && parentIDBytes.first == UInt8(ascii: "/")) {
                arena.append(contentsOf: parentIDBytes)
            }
            arena.append(UInt8(ascii: "/"))
            // Copied within the arena by pointer: appending a slice of itself would copy the whole arena.
            let destination = arena.count
            arena.append(contentsOf: repeatElement(0, count: name.count))
            arena.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                (base + destination).update(from: base + name.lowerBound, count: name.count)
            }
        } else {
            throw ScanSnapshotCacheError.corruptData("root node without explicit ID")
        }
        id = idStart..<arena.count
        guard !id.isEmpty else {
            throw ScanSnapshotCacheError.corruptData("node has empty ID")
        }

        var path: Range<Int>?
        if flags.contains(.hasExplicitPath) {
            let pathStart = arena.count
            try reader.readStringBytes(appendingTo: &arena)
            path = pathStart..<arena.count
        }
        let allocatedSize = try reader.readInt64()
        let unduplicatedSize = flags.contains(.hasUnduplicatedSize) ? try reader.readInt64() : allocatedSize
        let logicalSize = flags.contains(.hasLogicalSize) ? try reader.readInt64() : allocatedSize
        let hasCloudOnly = version >= 3 && flags.contains(.cloudOnly)
        let directoryCloudOnlySize: Int64 = hasCloudOnly && isDirectory ? try reader.readInt64() : 0
        let descendantFileCount = flags.contains(.hasDescendantFileCount)
            ? Int(try reader.readInt64())
            : (isDirectory ? 0 : 1)
        guard allocatedSize >= 0, unduplicatedSize >= 0, logicalSize >= 0,
              directoryCloudOnlySize >= 0, descendantFileCount >= 0 else {
            throw ScanSnapshotCacheError.corruptData(
                "node \(String(decoding: arena[id], as: UTF8.self)) has negative size or count"
            )
        }

        let modifiedSeconds = flags.contains(.hasLastModified) ? try reader.readDouble() : .nan

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
        var cloneInfo: CloneInfo?
        var summarizedClones: SummarizedClones?
        if version >= 4 {
            let extraFlags = NodeExtraFlags(rawValue: try reader.readUInt8())
            if extraFlags.contains(.hasCloneInfo) {
                let device = try reader.readUInt64()
                let cloneID = try reader.readUInt64()
                let refCount = try reader.readUInt32()
                let privateSize = try reader.readInt64()
                cloneInfo = CloneInfo(
                    device: device,
                    cloneID: cloneID,
                    refCount: max(refCount, 1),
                    privateSize: privateSize >= 0 ? privateSize : nil
                )
            }
            if version >= 5, extraFlags.contains(.hasSummarizedClones) {
                let count = Int(try reader.readUInt32())
                guard count <= reader.remainingByteCount / 44 else {
                    throw ScanSnapshotCacheError.corruptData(
                        "implausible clone family count \(count) for \(String(decoding: arena[id], as: UTF8.self))"
                    )
                }
                var families: [SummarizedCloneFamily] = []
                families.reserveCapacity(count)
                for _ in 0..<count {
                    let familyKey = CloneFamilyKey(device: try reader.readUInt64(), cloneID: try reader.readUInt64())
                    let memberCount = try reader.readUInt32()
                    let totalSize = try reader.readInt64()
                    let largestSize = try reader.readInt64()
                    let charge = try reader.readInt64()
                    guard totalSize >= 0, largestSize >= 0, charge >= 0 else {
                        throw ScanSnapshotCacheError.corruptData(
                            "node \(String(decoding: arena[id], as: UTF8.self)) has a negative clone size"
                        )
                    }
                    families.append(SummarizedCloneFamily(
                        familyKey: familyKey,
                        memberCount: memberCount,
                        totalSize: totalSize,
                        largestSize: largestSize,
                        charge: charge
                    ))
                }
                summarizedClones = SummarizedClones(families: families)
            }
        }
        // Bounded by the caller against the child slots left, cheaper than asking the stream per node.
        let childCount = Int(try reader.readUInt32())

        let isAccessible = !flags.contains(.isInaccessible)
        let node = PendingNode(
            id: id,
            name: name,
            path: path,
            isDirectory: isDirectory,
            isSymbolicLink: flags.contains(.isSymbolicLink),
            isPackage: flags.contains(.isPackage),
            isAccessible: isAccessible,
            isSelfAccessible: flags.contains(.selfAccessibilityDiffers) ? !isAccessible : isAccessible,
            isSynthetic: flags.contains(.isSynthetic),
            isAutoSummarized: flags.contains(.isAutoSummarized),
            isDataless: hasCloudOnly && !isDirectory,
            allocatedSize: allocatedSize,
            unduplicatedSize: unduplicatedSize,
            logicalSize: logicalSize,
            cloudOnlyLogicalSize: isDirectory ? directoryCloudOnlySize : nil,
            descendantFileCount: descendantFileCount,
            modifiedSeconds: modifiedSeconds,
            fileIdentity: fileIdentity,
            linkCount: max(linkCount, 1),
            cloneInfo: cloneInfo,
            summarizedClones: summarizedClones
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
