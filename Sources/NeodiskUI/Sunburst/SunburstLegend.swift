// Legend rows derive from the chart's rendered segments, so list and chart always agree (pooling,
// free space, fills). The view lives in SunburstLegendList.

import SunburstCore
import Foundation
import SwiftUI
import NeodiskKit
import NeodiskAppModel

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
    /// Undimmed semantic color published with hover for the status bar.
    let swatchRGB: SIMD3<Float>
    /// Aggregate and free/hidden-space rows render muted, like their
    /// segments.
    let isDimmed: Bool
    /// Pooled item count; non-zero only on the aggregate row.
    let itemCount: Int
    /// The size includes cloud-only bytes; drawn as a cloud glyph beside the size.
    var showsCloudGlyph: Bool = false
}

/// Structural legend output reused while only hover or selection changes.
struct SunburstLegendPresentation: Equatable {
    let header: SunburstLegendRow
    let rows: [SunburstLegendRow]
    let rowIDs: Set<String>
    let aggregateRowID: String?
    let freeSpaceRowID: String?
    let hiddenSpaceRowID: String?

    init(header: SunburstLegendRow, rows: [SunburstLegendRow]) {
        self.header = header
        self.rows = rows
        rowIDs = Set(rows.map(\.id))
        aggregateRowID = rows.first { $0.target == .aggregate }?.id
        freeSpaceRowID = rows.first { $0.target == .freeSpace }?.id
        hiddenSpaceRowID = rows.first { $0.target == .hiddenSpace }?.id
    }
}

struct SunburstLegendPresentationKey: Equatable {
    let renderedLayoutVersion: Int
    let displayedFolderID: String
    let chartRootID: String
    let style: SunburstColorStyle
    let includeCloudOnly: Bool
    /// The rows depend on this once a max-depth folder lays out its own ring,
    /// so it belongs in the key rather than relying on callers to invalidate.
    let expandedAggregateIDs: Set<String>
    let headerSizeOverride: Int64?
}

/// Single entry suffices: another folder is a structural replacement, and hover only changes overlays.
struct SunburstLegendPresentationCache {
    private var entry: (key: SunburstLegendPresentationKey, value: SunburstLegendPresentation)?
    private(set) var buildCount = 0

    mutating func value(
        for key: SunburstLegendPresentationKey,
        build: () -> SunburstLegendPresentation
    ) -> SunburstLegendPresentation {
        if let entry, entry.key == key { return entry.value }
        let value = build()
        entry = (key, value)
        buildCount += 1
        return value
    }

    mutating func removeAll() {
        entry = nil
    }
}

enum SunburstLegend {
    /// Children size-descending, then pooled, hidden and free space rows in the chart's order. An outermost
    /// folder has no segments, so the legend asks the layout for the ring it would have drawn.
    nonisolated static func rows(
        forFolder displayedFolderID: String,
        chartRootID: String,
        in store: FileTreeStore,
        segments: [SunburstSegment],
        style: SunburstColorStyle,
        includeCloudOnly: Bool = false,
        expandedAggregateIDs: Set<String> = []
    ) -> [SunburstLegendRow] {
        var childSegments: [SunburstSegment] = []
        var displayedFolderSegment: SunburstSegment?
        var aggregateSegment: SunburstSegment?
        var freeSpaceSegment: SunburstSegment?
        var hiddenSpaceSegment: SunburstSegment?
        for segment in segments {
            if let nodeID = segment.nodeID {
                if nodeID == displayedFolderID {
                    displayedFolderSegment = segment
                } else if store.parent(of: nodeID)?.id == displayedFolderID {
                    childSegments.append(segment)
                }
            } else if segment.isAggregate, segment.parentFolderID == displayedFolderID {
                aggregateSegment = segment
            } else if segment.isFreeSpace {
                freeSpaceSegment = segment
            } else if segment.isHiddenSpace {
                hiddenSpaceSegment = segment
            }
        }

        // Nothing rendered below this folder (last ring): lay that ring out now, one O(children) pass, pooled
        // the way drilling in would show it.
        if childSegments.isEmpty, aggregateSegment == nil {
            let depth = displayedFolderSegment.map { $0.depth + 1 }
                ?? max(store.path(to: displayedFolderID).count - store.path(to: chartRootID).count, 0)
            let ring = SunburstLayout.styled(
                SunburstLayout.ringSegments(
                    forFolder: displayedFolderID,
                    in: store,
                    depth: depth,
                    expandedAggregateIDs: expandedAggregateIDs,
                    includeCloudOnly: includeCloudOnly
                ),
                style: style,
                in: store
            )
            childSegments = ring.filter { !$0.isAggregate }
            aggregateSegment = ring.first { $0.isAggregate }
        }

        var rows: [SunburstLegendRow] = []
        rows.reserveCapacity(childSegments.count + 3)
        for segment in childSegments {
            guard let nodeID = segment.nodeID, let child = store.node(id: nodeID) else { continue }
            rows.append(SunburstLegendRow(
                id: child.id,
                target: .node(id: child.id, isDirectory: child.isSunburstFolder(in: store)),
                label: child.name,
                size: child.displayWeight(includingCloudOnly: includeCloudOnly),
                dotColor: SunburstChartStyler.baseStyle(for: segment).fillColor,
                swatchRGB: SunburstLayout.semanticFillRGB(
                    for: child, token: segment.colorToken, style: style
                ),
                isDimmed: false,
                itemCount: 0,
                showsCloudGlyph: includeCloudOnly && child.cloudOnlyLogicalSize > 0
            ))
        }

        if let aggregateSegment {
            rows.append(SunburstLegendRow(
                id: aggregateSegment.id,
                target: .aggregate,
                label: NSLocalizedString("Smaller Items", comment: "Sunburst legend pooled row"),
                size: aggregateSegment.totalSize,
                dotColor: SunburstChartStyler.baseStyle(for: aggregateSegment).fillColor,
                swatchRGB: FileKindCatalog.otherRGB,
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
                swatchRGB: SyntheticSpaceColors.hiddenSpaceRGB,
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
                swatchRGB: SyntheticSpaceColors.freeSpaceRGB,
                isDimmed: true,
                itemCount: 0
            ))
        }

        return rows
    }

    /// Colored like its own segment when drawn (a hovered preview), else via the fallback (the root has none).
    nonisolated static func headerRow(
        forFolder folder: FileNodeRecord,
        chartRootID: String,
        in store: FileTreeStore,
        segments: [SunburstSegment],
        style: SunburstColorStyle,
        includeCloudOnly: Bool = false,
        sizeOverride: Int64? = nil
    ) -> SunburstLegendRow {
        let colors: (dot: Color, swatch: SIMD3<Float>)
        if let segment = segments.first(where: { $0.nodeID == folder.id }) {
            colors = (
                SunburstChartStyler.baseStyle(for: segment).fillColor,
                SunburstLayout.semanticFillRGB(
                    for: folder, token: segment.colorToken, style: style
                )
            )
        } else {
            colors = fallbackColors(
                for: folder, chartRootID: chartRootID, in: store,
                style: style, includeCloudOnly: includeCloudOnly
            )
        }
        return SunburstLegendRow(
            id: "header-\(folder.id)",
            target: .node(id: folder.id, isDirectory: folder.isSunburstFolder(in: store)),
            label: folder.name,
            size: sizeOverride ?? folder.displayWeight(includingCloudOnly: includeCloudOnly),
            dotColor: colors.dot,
            swatchRGB: colors.swatch,
            isDimmed: false,
            itemCount: 0,
            // A disk-based override is never a cloud-inclusive figure.
            showsCloudGlyph: sizeOverride == nil && includeCloudOnly && folder.cloudOnlyLogicalSize > 0
        )
    }

    /// The direct child that contains the hovered node; nil when it isn't below the displayed folder.
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

    /// Built through the same machinery as rendered segments (synthetic segment, global color token), so it
    /// yields the color a real layout would.
    private nonisolated static func fallbackColors(
        for node: FileNodeRecord,
        chartRootID: String,
        in store: FileTreeStore,
        style: SunburstColorStyle,
        includeCloudOnly: Bool
    ) -> (dot: Color, swatch: SIMD3<Float>) {
        let coordinate = SunburstLayout.colorCoordinate(
            for: node.id, in: store, includeCloudOnly: includeCloudOnly
        ) ?? (start: 0, span: 1, depth: 0)
        let token = SunburstColorToken(
            midpoint: coordinate.start + coordinate.span / 2,
            depth: coordinate.depth,
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
            depth: max(store.path(to: node.id).count - store.path(to: chartRootID).count - 1, 0),
            colorToken: token,
            fillRGB: SunburstLayout.resolvedFillRGB(for: node, token: token, style: style),
            totalSize: node.allocatedSize,
            isAggregate: false
        )
        return (
            SunburstChartStyler.baseStyle(for: synthetic).fillColor,
            SunburstLayout.semanticFillRGB(for: node, token: token, style: style)
        )
    }
}
