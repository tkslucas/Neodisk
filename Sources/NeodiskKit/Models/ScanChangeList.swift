//
//  ScanChangeList.swift
//  Neodisk
//
//  The explicit answer to "what changed since the last scan": an exact diff
//  of two snapshot trees into Added / Deleted / Renamed / Grown / Shrunk
//  entries, sorted by how much each one moved the disk.
//
//  Unlike ScanSizeBaseline — the hashed, memory-frugal map that colors the
//  outline's per-node deltas — this diff runs over both full trees with real
//  paths and exact FileIdentity values, so it has no hash-collision risk and
//  can afford richer semantics: a moved node (same device+inode at a
//  different path, linkCount 1) is matched even when its size also changed,
//  and its entry carries the net delta. Both trees are only needed while
//  `build` runs; the result keeps just the capped entry list.
//
//  Noise control:
//  - Grown/shrunk are reported for leaves only (files, packages, summarized
//    folders) — directory growth is derivative of its children.
//  - A fully added/deleted subtree collapses into one entry for its
//    top-most node; partially affected directories report their qualifying
//    descendants instead.
//  - A moved directory is one renamed entry; everything beneath it (on both
//    the old and new side) is suppressed and summarized by that entry's
//    delta. Content that changed inside a moved directory therefore shows
//    as the renamed entry's delta, not as individual rows.
//  - Renames of small files (below identity capture — see
//    ScanSizeBaseline.renameTrackingMinimumFileSize) still read as
//    added+deleted; hard-linked files (shared identity) are never matched.
//

import Foundation

/// One row of the changes list.
public struct ScanChangeEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
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

    /// Deleted entries' old paths can't collide with current node IDs (the
    /// path is deleted precisely because no current node has it), so this
    /// is unique across one list.
    public var id: String { nodeID ?? path }
}

/// The diff of the displayed snapshot against its predecessor, as a flat
/// list sorted by |delta| (largest disk movement first; equal-size renames
/// sink to the end), capped to keep the UI and memory bounded.
public struct ScanChangeList: Sendable, Equatable {
    /// The subsets the UI's filter subtabs show. `all` is the full mixed
    /// list; `added`/`deleted` are per-kind lists capped independently of
    /// it, so their tails are not crowded out by the other kinds' big
    /// movers.
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

        // Previous-scan identity index for rename matching. Hard links and
        // synthetic nodes can't anchor a rename; an identity that appears
        // twice (shouldn't happen after the linkCount filter) is dropped as
        // ambiguous.
        var previousIndexByIdentity: [FileIdentity: Int32] = [:]
        for (index, node) in previous.storage.nodes.enumerated() {
            guard let identity = node.fileIdentity, node.linkCount == 1,
                  !node.isSynthetic else { continue }
            previousIndexByIdentity[identity] = previousIndexByIdentity[identity] == nil
                ? Int32(index)
                : ambiguousIndex
        }

        // Pass 1 — classify the current tree in preorder (parents first, so
        // subtree suppression is one parent lookup) and emit grown/shrunk
        // leaves and renamed entries along the way.
        let currentNodes = current.storage.nodes
        var currentClasses = [CurrentClass](repeating: .present, count: currentNodes.count)
        var consumedPreviousIndices = Set<Int32>()
        for index in currentNodes.indices {
            let node = currentNodes[index]
            let parentClass: CurrentClass? = current.storage
                .parentIndex(of: Int32(index))
                .map { currentClasses[Int($0)] }

            if node.isSynthetic || parentClass == .ignored {
                currentClasses[index] = .ignored
                continue
            }
            if parentClass == .moved || parentClass == .withinMoved {
                // Inside a moved subtree: the top-most renamed entry
                // summarizes everything beneath it.
                currentClasses[index] = .withinMoved
                continue
            }

            if let previousIndex = previous.storage.index(of: node.id) {
                currentClasses[index] = .present
                let previousNode = previous.storage.nodes[Int(previousIndex)]
                let delta = node.allocatedSize - previousNode.allocatedSize
                // Leaf in both trees (files, opaque packages, summarized
                // folders): a directory that emptied or filled is reported
                // through its children's deleted/added entries instead —
                // one row per change, no double counting.
                if delta != 0,
                   current.storage.childCount(of: Int32(index)) == 0,
                   previous.storage.childCount(of: previousIndex) == 0 {
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

            if let identity = node.fileIdentity, node.linkCount == 1,
               let previousIndex = previousIndexByIdentity[identity],
               previousIndex != ambiguousIndex,
               !consumedPreviousIndices.contains(previousIndex) {
                let previousNode = previous.storage.nodes[Int(previousIndex)]
                // The old path must be gone: an identity whose old path is
                // still occupied is an atomic-save/inode-migration artifact,
                // not a move.
                if current.storage.index(of: previousNode.id) == nil {
                    currentClasses[index] = .moved
                    consumedPreviousIndices.insert(previousIndex)
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

        // Pass 2 — collapse fully added subtrees: reverse preorder visits
        // children before parents, so each node can tell its parent whether
        // its whole subtree is added.
        var subtreeAllAdded = [Bool](repeating: true, count: currentNodes.count)
        for index in currentNodes.indices.reversed() {
            let isFullyAdded = currentClasses[index] == .added && subtreeAllAdded[index]
            if !isFullyAdded, let parent = current.storage.parentIndex(of: Int32(index)) {
                subtreeAllAdded[Int(parent)] = false
            }
        }
        for index in currentNodes.indices {
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

        // Pass 3 — the previous tree's side: what vanished. Rename sources
        // and everything beneath them are accounted for by their renamed
        // entries; fully deleted subtrees collapse like fully added ones.
        let previousNodes = previous.storage.nodes
        var previousClasses = [PreviousClass](repeating: .present, count: previousNodes.count)
        for index in previousNodes.indices {
            let node = previousNodes[index]
            let parentClass: PreviousClass? = previous.storage
                .parentIndex(of: Int32(index))
                .map { previousClasses[Int($0)] }

            if node.isSynthetic || parentClass == .ignored {
                previousClasses[index] = .ignored
            } else if parentClass == .movedSource || parentClass == .withinMovedSource {
                previousClasses[index] = .withinMovedSource
            } else if consumedPreviousIndices.contains(Int32(index)) {
                previousClasses[index] = .movedSource
            } else if current.storage.index(of: node.id) != nil {
                previousClasses[index] = .present
            } else {
                previousClasses[index] = .deleted
            }
        }
        var subtreeAllDeleted = [Bool](repeating: true, count: previousNodes.count)
        for index in previousNodes.indices.reversed() {
            let isFullyDeleted = previousClasses[index] == .deleted && subtreeAllDeleted[index]
            if !isFullyDeleted, let parent = previous.storage.parentIndex(of: Int32(index)) {
                subtreeAllDeleted[Int(parent)] = false
            }
        }
        for index in previousNodes.indices {
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

        // Per-kind subsets are carved out of the sorted-but-uncapped list,
        // so each filter keeps its own biggest movers even when the mixed
        // list's cap is dominated by another kind.
        var addedEntries: [ScanChangeEntry] = []
        var addedEntryCount = 0
        var deletedEntries: [ScanChangeEntry] = []
        var deletedEntryCount = 0
        for entry in entries {
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
