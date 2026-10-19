// Exact diff of two full trees (unlike the hashed ScanSizeBaseline), so moves match by identity even when resized.
// Noise control: leaves only for grown/shrunk, whole added/deleted/moved subtrees collapse into one entry.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One row of the changes list.
public struct ScanChangeEntry: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Equatable, CaseIterable, Codable {
        case added
        case deleted
        case renamed
        case grown
        case shrunk
    }

    public let kind: Kind
    /// The node's ID in the currently displayed tree; nil for deleted
    /// entries, whose node only exists in the previous scan.
    public let nodeID: String?
    public let name: String
    /// Current path (deleted entries: the old path).
    public let path: String
    /// Where a renamed/moved entry lived in the previous scan.
    public let previousPath: String?
    public let isDirectory: Bool
    /// Current allocated size (deleted entries: the size that went away).
    public let size: Int64
    /// Signed size change: added = +size, deleted = −oldSize, renamed and
    /// grown/shrunk = current − previous.
    public let delta: Int64

    /// Unique: a deleted entry's old path is deleted precisely because no current node has it.
    public var id: String { nodeID ?? path }
}

/// Sorted by |delta| (equal-size renames sink to the end) and capped to bound UI and memory.
public struct ScanChangeList: Sendable, Equatable, Codable {
    /// `added`/`deleted` are capped independently of `all`, so other kinds' big movers don't crowd them out.
    public enum Filter: String, Sendable, Equatable, CaseIterable, Identifiable {
        case all
        case added
        case deleted

        public var id: String { rawValue }
    }

    public let entries: [ScanChangeEntry]
    /// How many entries the diff produced before capping.
    public let totalEntryCount: Int
    /// Added entries only, sorted and capped like `entries`.
    public let addedEntries: [ScanChangeEntry]
    public let addedEntryCount: Int
    /// Deleted entries only, sorted and capped like `entries`.
    public let deletedEntries: [ScanChangeEntry]
    public let deletedEntryCount: Int
    /// Sum of every positive delta (added + grown + growing renames).
    public let addedBytes: Int64
    /// Magnitude of every negative delta (deleted + shrunk + shrinking renames).
    public let removedBytes: Int64
    public let renamedCount: Int

    private static let cancelled = ScanChangeList(
        entries: [], totalEntryCount: 0, addedEntries: [], addedEntryCount: 0,
        deletedEntries: [], deletedEntryCount: 0, addedBytes: 0, removedBytes: 0, renamedCount: 0
    )

    public var isEmpty: Bool { totalEntryCount == 0 }

    public func entries(for filter: Filter) -> [ScanChangeEntry] {
        switch filter {
        case .all: return entries
        case .added: return addedEntries
        case .deleted: return deletedEntries
        }
    }

    /// Pre-cap entry count of the filter's subset (for "Top X of Y" footers).
    public func totalCount(for filter: Filter) -> Int {
        switch filter {
        case .all: return totalEntryCount
        case .added: return addedEntryCount
        case .deleted: return deletedEntryCount
        }
    }

    /// Diffs `current` against `previous`. O(nodes) over both trees; run it
    /// off the main actor for large scans.
    public static func build(
        current: FileTreeStore,
        previous: FileTreeStore,
        entryLimit: Int = 500
    ) -> ScanChangeList {
        var entries: [ScanChangeEntry] = []

        // Hard links and synthetic nodes can't anchor a rename; a duplicate identity is dropped as ambiguous.
        var previousIndexByIdentity: [FileIdentity: Int32] = [:]
        for (index, node) in previous.storage.nodes.enumerated() {
            if Task.isCancelled { return .cancelled }
            guard let identity = node.fileIdentity, node.linkCount == 1,
                  !node.isSynthetic else { continue }
            previousIndexByIdentity[identity] = previousIndexByIdentity[identity] == nil
                ? Int32(index)
                : ambiguousIndex
        }

        // Pass 1, preorder (parents first, so subtree suppression is one parent lookup).
        let currentNodes = current.storage.nodes
        let currentStorage = current.storage
        let previousStorage = previous.storage
        var currentClasses = [CurrentClass](repeating: .present, count: currentNodes.count)
        var consumedPreviousIndices = Set<Int32>()
        for index in currentNodes.indices {
            if Task.isCancelled { return .cancelled }
            // Read fields off the storage array so classifying a node retains no Strings.
            let parentClass: CurrentClass? = currentStorage
                .parentIndex(of: Int32(index))
                .map { currentClasses[Int($0)] }

            if currentNodes[index].isSynthetic || parentClass == .ignored {
                currentClasses[index] = .ignored
                continue
            }
            if parentClass == .moved || parentClass == .withinMoved {
                // Inside a moved subtree: the top-most renamed entry
                // summarizes everything beneath it.
                currentClasses[index] = .withinMoved
                continue
            }

            // Reuses the stored hash instead of rehashing the path; string equality still decides the match.
            let nodeHash = currentStorage.nodeHash(at: index)
            if let previousIndex = previousStorage.index(of: currentNodes[index].id, hash: nodeHash) {
                currentClasses[index] = .present
                let delta = currentNodes[index].allocatedSize
                    - previousStorage.nodes[Int(previousIndex)].allocatedSize
                // Leaf in both trees: a directory that emptied or filled reports through its children instead.
                if delta != 0,
                   currentStorage.childCount(of: Int32(index)) == 0,
                   previousStorage.childCount(of: previousIndex) == 0 {
                    let node = currentNodes[index]
                    entries.append(ScanChangeEntry(
                        kind: delta > 0 ? .grown : .shrunk,
                        nodeID: node.id,
                        name: node.name,
                        path: node.path,
                        previousPath: nil,
                        isDirectory: node.isDirectory,
                        size: node.allocatedSize,
                        delta: delta
                    ))
                }
                continue
            }

            if let identity = currentNodes[index].fileIdentity, currentNodes[index].linkCount == 1,
               let previousIndex = previousIndexByIdentity[identity],
               previousIndex != ambiguousIndex,
               !consumedPreviousIndices.contains(previousIndex) {
                let previousNode = previousStorage.nodes[Int(previousIndex)]
                // An identity whose old path is still occupied is an atomic-save artifact, not a move.
                if currentStorage.index(
                    of: previousNode.id,
                    hash: previousStorage.nodeHash(at: Int(previousIndex))
                ) == nil {
                    currentClasses[index] = .moved
                    consumedPreviousIndices.insert(previousIndex)
                    let node = currentNodes[index]
                    entries.append(ScanChangeEntry(
                        kind: .renamed,
                        nodeID: node.id,
                        name: node.name,
                        path: node.path,
                        previousPath: previousNode.path,
                        isDirectory: node.isDirectory,
                        size: node.allocatedSize,
                        delta: node.allocatedSize - previousNode.allocatedSize
                    ))
                    continue
                }
            }

            currentClasses[index] = .added
        }

        // Pass 2: reverse preorder visits children first, so each tells its parent if its subtree is all added.
        var subtreeAllAdded = [Bool](repeating: true, count: currentNodes.count)
        for index in currentNodes.indices.reversed() {
            if Task.isCancelled { return .cancelled }
            let isFullyAdded = currentClasses[index] == .added && subtreeAllAdded[index]
            if !isFullyAdded, let parent = current.storage.parentIndex(of: Int32(index)) {
                subtreeAllAdded[Int(parent)] = false
            }
        }
        for index in currentNodes.indices {
            if Task.isCancelled { return .cancelled }
            guard currentClasses[index] == .added, subtreeAllAdded[index] else { continue }
            if let parent = current.storage.parentIndex(of: Int32(index)),
               currentClasses[Int(parent)] == .added, subtreeAllAdded[Int(parent)] {
                continue
            }
            let node = currentNodes[index]
            entries.append(ScanChangeEntry(
                kind: .added,
                nodeID: node.id,
                name: node.name,
                path: node.path,
                previousPath: nil,
                isDirectory: node.isDirectory,
                size: node.allocatedSize,
                delta: node.allocatedSize
            ))
        }

        // Pass 3, the previous tree: rename sources and their subtrees are covered by the renamed entries.
        let previousNodes = previousStorage.nodes
        var previousClasses = [PreviousClass](repeating: .present, count: previousNodes.count)
        for index in previousNodes.indices {
            if Task.isCancelled { return .cancelled }
            let parentClass: PreviousClass? = previousStorage
                .parentIndex(of: Int32(index))
                .map { previousClasses[Int($0)] }

            if previousNodes[index].isSynthetic || parentClass == .ignored {
                previousClasses[index] = .ignored
            } else if parentClass == .movedSource || parentClass == .withinMovedSource {
                previousClasses[index] = .withinMovedSource
            } else if consumedPreviousIndices.contains(Int32(index)) {
                previousClasses[index] = .movedSource
            } else if currentStorage.index(
                of: previousNodes[index].id,
                hash: previousStorage.nodeHash(at: index)
            ) != nil {
                previousClasses[index] = .present
            } else {
                previousClasses[index] = .deleted
            }
        }
        var subtreeAllDeleted = [Bool](repeating: true, count: previousNodes.count)
        for index in previousNodes.indices.reversed() {
            if Task.isCancelled { return .cancelled }
            let isFullyDeleted = previousClasses[index] == .deleted && subtreeAllDeleted[index]
            if !isFullyDeleted, let parent = previous.storage.parentIndex(of: Int32(index)) {
                subtreeAllDeleted[Int(parent)] = false
            }
        }
        for index in previousNodes.indices {
            if Task.isCancelled { return .cancelled }
            guard previousClasses[index] == .deleted, subtreeAllDeleted[index] else { continue }
            if let parent = previous.storage.parentIndex(of: Int32(index)),
               previousClasses[Int(parent)] == .deleted, subtreeAllDeleted[Int(parent)] {
                continue
            }
            let node = previousNodes[index]
            entries.append(ScanChangeEntry(
                kind: .deleted,
                nodeID: nil,
                name: node.name,
                path: node.path,
                previousPath: nil,
                isDirectory: node.isDirectory,
                size: node.allocatedSize,
                delta: -node.allocatedSize
            ))
        }

        // Summaries cover every entry; the list itself is capped after
        // sorting so the biggest movements always survive the cut.
        var addedBytes: Int64 = 0
        var removedBytes: Int64 = 0
        var renamedCount = 0
        for entry in entries {
            if Task.isCancelled { return .cancelled }
            if entry.delta > 0 {
                addedBytes = addedBytes.addingClamped(entry.delta)
            } else {
                removedBytes = removedBytes.addingClamped(-entry.delta)
            }
            if entry.kind == .renamed {
                renamedCount += 1
            }
        }

        entries.sort { lhs, rhs in
            if lhs.delta.magnitude != rhs.delta.magnitude {
                return lhs.delta.magnitude > rhs.delta.magnitude
            }
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            return lhs.path < rhs.path
        }
        let totalEntryCount = entries.count

        // Carved from the uncapped list so each filter keeps its own biggest movers.
        var addedEntries: [ScanChangeEntry] = []
        var addedEntryCount = 0
        var deletedEntries: [ScanChangeEntry] = []
        var deletedEntryCount = 0
        for entry in entries {
            if Task.isCancelled { return .cancelled }
            switch entry.kind {
            case .added:
                addedEntryCount += 1
                if addedEntries.count < entryLimit { addedEntries.append(entry) }
            case .deleted:
                deletedEntryCount += 1
                if deletedEntries.count < entryLimit { deletedEntries.append(entry) }
            case .renamed, .grown, .shrunk:
                break
            }
        }

        if entries.count > entryLimit {
            entries.removeLast(entries.count - entryLimit)
        }

        return ScanChangeList(
            entries: entries,
            totalEntryCount: totalEntryCount,
            addedEntries: addedEntries,
            addedEntryCount: addedEntryCount,
            deletedEntries: deletedEntries,
            deletedEntryCount: deletedEntryCount,
            addedBytes: addedBytes,
            removedBytes: removedBytes,
            renamedCount: renamedCount
        )
    }

    /// Equal digests mean an empty diff, so the cache keeps the older baseline instead of rotating. Timestamps
    /// are excluded: a scan that only touched them would otherwise destroy the baseline.
    public static func contentDigest(of store: FileTreeStore) -> String {
        contentDigest(of: store, checkCancellation: {})
    }

    public static func contentDigest(of store: FileTreeStore, checkCancellation: () throws -> Void) rethrows -> String {
        var hasher = SHA256()
        func updateInteger<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
        }
        // Display preorder, as the codec writes: array order can lag an in-place re-sort.
        let storage = store.storage
        var visited = 0
        try storage.forEachIndexInDisplayPreorder { index in
            if visited & 1023 == 0 { try checkCancellation() }
            visited += 1
            let node = storage.nodes[Int(index)]
            var id = node.id
            // Length-prefixed: IDs can contain any byte (synthetic nodes
            // embed NUL), so a separator can't delimit them.
            id.withUTF8 { idBytes in
                updateInteger(UInt64(idBytes.count))
                hasher.update(bufferPointer: UnsafeRawBufferPointer(idBytes))
            }
            updateInteger(node.allocatedSize)
            updateInteger(node.linkCount)
            updateInteger(node.isSynthetic ? UInt8(1) : UInt8(0))
            switch node.fileIdentity {
            case nil:
                updateInteger(UInt8(0))
            case .fileSystem(let device, let inode):
                updateInteger(UInt8(1))
                updateInteger(device)
                updateInteger(inode)
            case .resourceIdentifier(let data):
                updateInteger(UInt8(2))
                updateInteger(UInt64(data.count))
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let ambiguousIndex: Int32 = -1

    private enum CurrentClass: UInt8 {
        /// Exists in both scans at the same path.
        case present
        /// Matched a previous node by identity at a different path.
        case moved
        /// Beneath a moved node; summarized by its renamed entry.
        case withinMoved
        /// Not in the previous scan and not a move.
        case added
        /// Synthetic node (or beneath one); not a real filesystem change.
        case ignored
    }

    private enum PreviousClass: UInt8 {
        case present
        /// Consumed as a rename source by a current node.
        case movedSource
        /// Beneath a rename source; summarized by its renamed entry.
        case withinMovedSource
        case deleted
        case ignored
    }
}
