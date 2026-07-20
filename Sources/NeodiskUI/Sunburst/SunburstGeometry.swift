//
//  SunburstGeometry.swift
//  Neodisk
//
//  App-side glue over SunburstCore's pure layout: the color style (kind/age
//  modes lean on NeodiskUI's FileKindCatalog/VizPalette), the `styled` fill
//  pass that resolves each segment's final RGB, and the SwiftUI `Path`
//  construction for the arcs. The layout, grouping, hit-testing, branch-hue
//  math, and zoom remap all live in SunburstCore.
//

import SwiftUI
import NeodiskKit
import SunburstCore

extension FileNodeRecord {
    /// Whether the sunburst treats this node as a drillable folder. Packages
    /// (.app, .imovielibrary, …) are directories on disk, but the scan keeps
    /// them opaque, so the sunburst treats them as files: gray in branch
    /// mode, Quick Look on click, never a drill target. Once "Show Package
    /// Contents" splices a package's children into the store it behaves like
    /// any other folder.
    nonisolated func isSunburstFolder(in store: FileTreeStore) -> Bool {
        SunburstLayout.isSunburstFolder(self, in: store)
    }
}

/// How sunburst segments are colored, derived from the active analysis tab:
/// The branch-hue algorithm on Largest (folders colored, files gray,
/// colorblind palette honored), the treemap's kind/age semantics on the
/// other tabs. Every mode resolves its final fill (including highlight
/// dimming) into `SunburstSegment.fillRGB` via the `styled` pass; the
/// styler's token fallback only covers segments without a node.
struct SunburstColorStyle: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Branch hues — the global size-midpoint wheel, scan-root
        /// anchored (Largest tab).
        case branch
        /// Kind catalog colors, directories neutral (Kinds/Duplicates tabs).
        case kind
        /// Modification-age ramp against the scan date (Age tab).
        case age(referenceDate: Date)
    }

    var mode: Mode = .branch
    var catalog: FileKindCatalog = .empty
    var highlight: TreemapHighlight?
    var palette: VizPalette = .standard

    static func == (lhs: SunburstColorStyle, rhs: SunburstColorStyle) -> Bool {
        lhs.mode == rhs.mode
            && lhs.catalog.buildID == rhs.catalog.buildID
            && lhs.highlight == rhs.highlight
            && lhs.palette == rhs.palette
    }
}

extension SunburstLayout {
    /// Layout and fills in one call — the convenience for tests and callers
    /// that don't restyle; the chart itself lays out once and restyles via
    /// `styled` as colors change.
    nonisolated static func segments(
        in treeStore: FileTreeStore,
        rootID: String,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90,
        style: SunburstColorStyle = SunburstColorStyle(),
        freeSpaceBytes: Int64? = nil,
        hiddenSpaceBytes: Int64? = nil,
        expandedAggregateIDs: Set<String> = [],
        includeCloudOnly: Bool = false
    ) -> [SunburstSegment] {
        let unstyled = (try? segments(
            in: treeStore,
            rootID: rootID,
            depthLimit: depthLimit,
            minimumAngle: minimumAngle,
            freeSpaceBytes: freeSpaceBytes,
            hiddenSpaceBytes: hiddenSpaceBytes,
            expandedAggregateIDs: expandedAggregateIDs,
            includeCloudOnly: includeCloudOnly,
            freeSpaceLabel: NSLocalizedString("Free Space", comment: "Sunburst free-space segment label"),
            hiddenSpaceLabel: NSLocalizedString("Hidden Space", comment: "Sunburst hidden-space segment label"),
            cancellationCheck: {}
        )) ?? []
        return styled(unstyled, style: style, in: treeStore)
    }

    /// Re-resolves every segment's fill for a color style — O(segments), so
    /// tab, palette, highlight, and catalog changes recolor the finished
    /// layout instead of recomputing it.
    nonisolated static func styled(
        _ segments: [SunburstSegment],
        style: SunburstColorStyle,
        in treeStore: FileTreeStore
    ) -> [SunburstSegment] {
        segments.map { segment in
            var segment = segment
            segment.fillRGB = segment.nodeID
                .flatMap { treeStore.node(id: $0) }
                .flatMap { resolvedFillRGB(for: $0, token: segment.colorToken, style: style) }
            return segment
        }
    }

    // MARK: - Fill resolution

    /// A node's final fill, resolved by the `styled` pass. Kind/age modes
    /// mirror the treemap: kind catalog colors (directories neutral), the
    /// age ramp, and `TreemapScene.dimmedRGB` for segments a highlight
    /// doesn't match.
    /// Branch mode resolves the token (branch hues honoring the palette —
    /// colorblind branches restrict to Okabe-Ito hues — and gray files).
    /// Internal (not private) so the legend list can resolve the same fill
    /// for nodes without a rendered segment (children of a max-depth folder).
    nonisolated static func resolvedFillRGB(
        for node: FileNodeRecord,
        token: SunburstColorToken,
        style: SunburstColorStyle
    ) -> SIMD3<Float>? {
        var rgb: SIMD3<Float>
        switch style.mode {
        case .branch:
            return SunburstColorResolver.rgb(for: token, palette: style.palette.sunburst)
        case .kind:
            rgb = style.catalog.rgb(for: node)
        case .age(let referenceDate):
            if FileKindClassifier.isLeafLike(node) {
                rgb = style.palette.ageRGB(AgeBucket.bucket(for: node.lastModified, reference: referenceDate))
            } else {
                rgb = FileKindCatalog.directoryRGB
            }
        }
        // Only .kind and .age reach here (.branch returns above), so the
        // highlight-match predicate is shared with the treemap unchanged —
        // map this mode onto the treemap's for the one .age case it reads.
        if let highlight = style.highlight,
           !TreemapScene.matches(
               node,
               highlight: highlight,
               colorMode: style.mode.treemapColorMode,
               catalog: style.catalog
           ) {
            rgb = TreemapScene.dimmedRGB(rgb)
        }
        return rgb
    }
}

private extension SunburstColorStyle.Mode {
    /// The treemap color mode this maps to, so both visualizations share one
    /// highlight-match predicate (`TreemapScene.matches`). Only the `.age`
    /// reference date is load-bearing there; `.branch` never reaches the
    /// predicate, so it collapses to `.kind` like any non-age mode.
    var treemapColorMode: TreemapColorMode {
        switch self {
        case .age(let referenceDate): return .age(referenceDate: referenceDate)
        case .kind, .branch: return .kind
        }
    }
}

enum SunburstRenderer {
    nonisolated static func path(for segment: SunburstSegment, in size: CGSize) -> Path {
        path(
            startRadians: segment.startAngle,
            endRadians: segment.endAngle,
            innerRadius: segment.innerRadius,
            outerRadius: segment.outerRadius,
            in: size
        )
    }

    /// Same arc construction for transient geometry (the zoom transition's
    /// remapped arcs), which is not backed by a SunburstSegment.
    nonisolated static func path(for arc: SunburstZoomArc, in size: CGSize) -> Path {
        path(
            startRadians: arc.startRadians,
            endRadians: arc.endRadians,
            innerRadius: arc.innerRadius,
            outerRadius: arc.outerRadius,
            in: size
        )
    }

    private nonisolated static func path(
        startRadians: Double,
        endRadians: Double,
        innerRadius: Double,
        outerRadius: Double,
        in size: CGSize
    ) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        let (seamStart, seamEnd) = SunburstArcGeometry.seamInsetAngles(
            startRadians: startRadians,
            endRadians: endRadians,
            innerRadius: innerRadius,
            outerRadius: outerRadius
        )
        let innerRadius = maxRadius * CGFloat(innerRadius)
        let outerRadius = maxRadius * CGFloat(outerRadius)

        let start = seamStart - (.pi / 2)
        let end = seamEnd - (.pi / 2)

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(start),
            endAngle: .radians(end),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(end),
            endAngle: .radians(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}
