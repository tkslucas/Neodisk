//
//  SunburstLegend.swift
//  Neodisk
//
//  Pure derivation of the DaisyDisk-style legend list next to the sunburst:
//  one row per child of the displayed folder, colored exactly like that
//  child's chart segment. Rows derive from the chart's rendered segments so
//  the list and the chart always agree — same aggregate pooling, same
//  free-space arc, same fills. View-free and stateless for testability;
//  the view lives in SunburstLegendList.
//

import SunburstCore
import Foundation
import SwiftUI
import NeodiskKit

/// One legend list row: a child of the displayed folder, the pooled
/// "Smaller Items" aggregate, or the synthetic free/hidden-space arcs.
struct SunburstLegendRow: Identifiable, Equatable {
    enum Target: Equatable {
        case node(id: String, isDirectory: Bool)
        case aggregate
        case freeSpace
        case hiddenSpace
    }

    let id: String
    let target: Target
    let label: String
    let size: Int64
    /// The exact fill the chart draws (or would draw) for this entry.
    let dotColor: Color
    /// Aggregate and free/hidden-space rows render muted, like their
    /// segments.
    let isDimmed: Bool
    /// Pooled item count; non-zero only on the aggregate row.
    let itemCount: Int
    /// Marks a row whose size includes cloud-only bytes (the cloud-only
    /// toggle is on and the node has some) — rendered as a small cloud
    /// glyph beside the size.
    var showsCloudGlyph: Bool = false
}

enum SunburstLegend {
    /// The children of `displayedFolderID`, size-descending, followed by one
    /// pooled "Smaller Items" row when the chart pooled some of them, then
    /// "Hidden Space" and "Free Space" rows when the chart shows those arcs
    /// (only at the chart root — both belong to the volume ring, in the
    /// chart's angular order).
    ///
    /// Colors come from the rendered segments where the chart drew one; a
    /// child without a segment (its ring is beyond the depth limit) falls
    /// back to the same color-resolution path the layout uses, so it matches
    /// what the chart would render at that depth.
    nonisolated static func rows(
        forFolder displayedFolderID: String,
        chartRootID: String,
        in store: FileTreeStore,
        segments: [SunburstSegment],
        style: SunburstColorStyle,
        includeCloudOnly: Bool = false
    ) -> [SunburstLegendRow] {
        var segmentByNodeID: [String: SunburstSegment] = [:]
        var aggregateSegment: SunburstSegment?
        var freeSpaceSegment: SunburstSegment?
        var hiddenSpaceSegment: SunburstSegment?
        for segment in segments {
            if let nodeID = segment.nodeID {
                segmentByNodeID[nodeID] = segment
            } else if segment.isAggregate, segment.parentFolderID == displayedFolderID {
                aggregateSegment = segment
            } else if segment.isFreeSpace {
                freeSpaceSegment = segment
            } else if segment.isHiddenSpace {
                hiddenSpaceSegment = segment
            }
        }

        // Sort by the same weight the chart lays arcs out with, so the
        // legend order matches the ring.
        let children = store.children(of: displayedFolderID).sorted { lhs, rhs in
            let lhsWeight = lhs.displayWeight(includingCloudOnly: includeCloudOnly)
            let rhsWeight = rhs.displayWeight(includingCloudOnly: includeCloudOnly)
            return lhsWeight != rhsWeight ? lhsWeight > rhsWeight : lhs.name < rhs.name
        }

        var rows: [SunburstLegendRow] = []
        rows.reserveCapacity(children.count + 2)
        for child in children {
            let size = child.displayWeight(includingCloudOnly: includeCloudOnly)
            let showsCloudGlyph = includeCloudOnly && child.cloudOnlyLogicalSize > 0
            if let segment = segmentByNodeID[child.id] {
                rows.append(SunburstLegendRow(
                    id: child.id,
                    target: .node(id: child.id, isDirectory: child.isSunburstFolder(in: store)),
                    label: child.name,
                    size: size,
                    dotColor: SunburstChartStyler.baseStyle(for: segment).fillColor,
                    isDimmed: false,
                    itemCount: 0,
                    showsCloudGlyph: showsCloudGlyph
                ))
            } else if aggregateSegment != nil {
                // The chart pooled this child into the aggregate segment —
                // it appears in the combined "Smaller Items" row instead.
                continue
            } else {
                // No ring rendered for this folder's children (beyond the
                // depth limit): color the row the way the chart would.
                rows.append(SunburstLegendRow(
                    id: child.id,
                    target: .node(id: child.id, isDirectory: child.isSunburstFolder(in: store)),
                    label: child.name,
                    size: size,
                    dotColor: fallbackDotColor(for: child, chartRootID: chartRootID, in: store, style: style),
                    isDimmed: false,
                    itemCount: 0,
                    showsCloudGlyph: showsCloudGlyph
                ))
            }
        }

        if let aggregateSegment {
            rows.append(SunburstLegendRow(
                id: aggregateSegment.id,
                target: .aggregate,
                label: NSLocalizedString("Smaller Items", comment: "Sunburst legend pooled row"),
                size: aggregateSegment.totalSize,
                dotColor: SunburstChartStyler.baseStyle(for: aggregateSegment).fillColor,
                isDimmed: true,
                itemCount: aggregateSegment.itemCount
            ))
        }

        if displayedFolderID == chartRootID, let hiddenSpaceSegment {
            rows.append(SunburstLegendRow(
                id: hiddenSpaceSegment.id,
                target: .hiddenSpace,
                label: NSLocalizedString("Hidden Space", comment: "Sunburst legend hidden-space row"),
                size: hiddenSpaceSegment.totalSize,
                dotColor: SunburstChartStyler.baseStyle(for: hiddenSpaceSegment).fillColor,
                isDimmed: true,
                itemCount: 0
            ))
        }

        if displayedFolderID == chartRootID, let freeSpaceSegment {
            rows.append(SunburstLegendRow(
                id: freeSpaceSegment.id,
                target: .freeSpace,
                label: NSLocalizedString("Free Space", comment: "Sunburst legend free-space row"),
                size: freeSpaceSegment.totalSize,
                dotColor: SunburstChartStyler.baseStyle(for: freeSpaceSegment).fillColor,
                isDimmed: true,
                itemCount: 0
            ))
        }

        return rows
    }

    /// The legend's header entry: the displayed folder itself with its total
    /// size, colored like its own segment when the chart drew one (a hovered
    /// preview folder) or via the fallback path (the chart root has no
    /// segment of its own).
    nonisolated static func headerRow(
        forFolder folder: FileNodeRecord,
        chartRootID: String,
        in store: FileTreeStore,
        segments: [SunburstSegment],
        style: SunburstColorStyle,
        includeCloudOnly: Bool = false,
        sizeOverride: Int64? = nil
    ) -> SunburstLegendRow {
        let dotColor: Color
        if let segment = segments.first(where: { $0.nodeID == folder.id }) {
            dotColor = SunburstChartStyler.baseStyle(for: segment).fillColor
        } else {
            dotColor = fallbackDotColor(for: folder, chartRootID: chartRootID, in: store, style: style)
        }
        return SunburstLegendRow(
            id: "header-\(folder.id)",
            target: .node(id: folder.id, isDirectory: folder.isSunburstFolder(in: store)),
            label: folder.name,
            size: sizeOverride ?? folder.displayWeight(includingCloudOnly: includeCloudOnly),
            dotColor: dotColor,
            isDimmed: false,
            itemCount: 0,
            // A disk-based override is never a cloud-inclusive figure.
            showsCloudGlyph: sizeOverride == nil && includeCloudOnly && folder.cloudOnlyLogicalSize > 0
        )
    }

    /// Maps a hovered node anywhere below the displayed folder to the row
    /// that contains it: the node itself when it is a direct child, otherwise
    /// its ancestor that is a direct child. Nil when the node is not below
    /// the displayed folder (or is the folder itself).
    nonisolated static func rowNodeID(
        forHovered nodeID: String,
        displayedFolderID: String,
        in store: FileTreeStore
    ) -> String? {
        var currentID = nodeID
        while let parent = store.parent(of: currentID) {
            if parent.id == displayedFolderID {
                return currentID
            }
            currentID = parent.id
        }
        return nil
    }

    /// The fill the chart would give `node` at its depth below the chart
    /// root, built through the exact same machinery as rendered segments: a
    /// synthetic segment with the layout's resolved fill (kind/age modes) or
    /// branch color token (Largest), styled by SunburstChartStyler. The
    /// resolver only reads branchID/localID/depth, so the simplified token
    /// yields the same color a real layout would.
    private nonisolated static func fallbackDotColor(
        for node: FileNodeRecord,
        chartRootID: String,
        in store: FileTreeStore,
        style: SunburstColorStyle
    ) -> Color {
        let depth = max(
            store.path(to: node.id).count - store.path(to: chartRootID).count - 1,
            0
        )
        let token = SunburstColorToken(
            branchID: SunburstLayout.topLevelBranchID(for: node.id, in: store) ?? node.id,
            localID: node.id,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: node.isSunburstFolder(in: store) ? .normal : .file
        )
        let synthetic = SunburstSegment(
            id: "legend-\(node.id)",
            nodeID: node.id,
            label: node.name,
            startAngle: .zero,
            endAngle: .zero,
            innerRadius: 0,
            outerRadius: 0,
            depth: depth,
            colorToken: token,
            fillRGB: SunburstLayout.resolvedFillRGB(for: node, token: token, style: style),
            totalSize: node.allocatedSize,
            isAggregate: false
        )
        return SunburstChartStyler.baseStyle(for: synthetic).fillColor
    }
}
