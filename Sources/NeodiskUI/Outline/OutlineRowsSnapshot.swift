//
//  OutlineRowsSnapshot.swift
//  Neodisk
//
//  Cached structural input for both AppKit outline tables. Selection and
//  hover never enter the cache key, so moving through an already-expanded
//  tree reuses the flattened rows and their ID index verbatim.
//

import Foundation
import NeodiskKit

extension NeodiskViewModel {
    struct OutlineRowsSnapshot {
        let structuralVersion: UInt64
        let rows: [OutlineRow]
        let rowIndexByID: [String: Int]
        /// Natural row width for the horizontally scrolling leading outline.
        /// The bottom table owns fixed columns and leaves this at zero.
        let contentWidth: CGFloat
    }

    /// Returns the cached structural rows for one outline layout. The two
    /// layouts keep independent one-entry caches because the bottom table's
    /// header sort changes sibling order while the leading outline keeps the
    /// store's size order.
    func outlineRowsSnapshot(sortedBy sort: OutlineSort? = nil) -> OutlineRowsSnapshot {
        let key = OutlineRowsCache.Key(
            snapshotID: coordinator.snapshot?.id,
            effectiveRootID: effectiveRootID,
            expansionRevision: outlineExpansionRevision,
            sort: sort,
            baselineTargetID: diff.baseline?.targetID,
            baselineFinishedAt: diff.baseline?.finishedAt,
            includesCloudOnly: showsCloudOnlyFiles
        )
        return outlineRowsCache.snapshot(for: key) { version in
            let rows = flattenVisibleOutlineRows(sortedBy: sort)
            let rowIndexByID = Dictionary(
                uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) }
            )
            let contentWidth = sort == nil
                ? OutlineRowMetrics.contentWidth(
                    for: rows,
                    baseline: diff.baseline,
                    includeCloudOnly: showsCloudOnlyFiles
                )
                : 0
            return OutlineRowsSnapshot(
                structuralVersion: version,
                rows: rows,
                rowIndexByID: rowIndexByID,
                contentWidth: contentWidth
            )
        }
    }
}

/// Two-slot cache owned by one view model. A slot is overwritten on every
/// real structural change, so old flattened trees are released promptly.
@MainActor
final class OutlineRowsCache {
    struct Key: Equatable {
        let snapshotID: UUID?
        let effectiveRootID: String?
        let expansionRevision: UInt64
        let sort: OutlineSort?
        let baselineTargetID: String?
        let baselineFinishedAt: Date?
        let includesCloudOnly: Bool
    }

    private struct Entry {
        let key: Key
        let snapshot: NeodiskViewModel.OutlineRowsSnapshot
    }

    private var leadingEntry: Entry?
    private var bottomEntry: Entry?
    private var nextVersion: UInt64 = 1
    private(set) var buildCount = 0

    func snapshot(
        for key: Key,
        build: (UInt64) -> NeodiskViewModel.OutlineRowsSnapshot
    ) -> NeodiskViewModel.OutlineRowsSnapshot {
        let cached = key.sort == nil ? leadingEntry : bottomEntry
        if let cached, cached.key == key {
            return cached.snapshot
        }

        let version = nextVersion
        nextVersion &+= 1
        buildCount += 1
        let entry = Entry(key: key, snapshot: build(version))
        if key.sort == nil {
            leadingEntry = entry
        } else {
            bottomEntry = entry
        }
        return entry.snapshot
    }
}
