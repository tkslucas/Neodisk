// App-side glue over SunburstCore's layout shared by every shell; drawing is each platform's business.

import Foundation
import NeodiskKit
import SunburstCore

extension FileNodeRecord {
    /// Packages are directories on disk but the scan keeps them opaque, so they act as files until "Show
    /// Package Contents" splices their children in.
    package nonisolated func isSunburstFolder(in store: FileTreeStore) -> Bool {
        SunburstLayout.isSunburstFolder(self, in: store)
    }
}

/// Branch hues on Largest, the treemap's kind/age semantics elsewhere. Every mode resolves its final fill
/// into `fillRGB` via `styled`; the token fallback only covers nodeless segments.
package struct SunburstColorStyle: Equatable, Sendable {
    package enum Mode: Equatable, Sendable {
        /// Branch hues — the global size-midpoint wheel, scan-root
        /// anchored (Largest tab).
        case branch
        /// Kind catalog colors, directories neutral (Kinds/Duplicates tabs).
        case kind
        /// Modification-age ramp against the scan date (Age tab).
        case age(referenceDate: Date)
    }

    package var mode: Mode = .branch
    package var catalog: FileKindCatalog = .empty
    package var highlight: TreemapHighlight?
    package var palette: VizPalette = .standard

    package init(
        mode: Mode = .branch,
        catalog: FileKindCatalog = .empty,
        highlight: TreemapHighlight? = nil,
        palette: VizPalette = .standard
    ) {
        self.mode = mode
        self.catalog = catalog
        self.highlight = highlight
        self.palette = palette
    }

    package static func == (lhs: SunburstColorStyle, rhs: SunburstColorStyle) -> Bool {
        lhs.mode == rhs.mode
            && lhs.catalog.buildID == rhs.catalog.buildID
            && lhs.highlight == rhs.highlight
            && lhs.palette == rhs.palette
    }
}

extension SunburstLayout {
    /// For tests and callers that don't restyle; the chart lays out once and restyles via `styled`.
    package nonisolated static func segments(
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
            freeSpaceLabel: AppStrings.localized("Free Space", comment: "Sunburst free-space segment label"),
            hiddenSpaceLabel: AppStrings.localized("Hidden Space", comment: "Sunburst hidden-space segment label"),
            cancellationCheck: {}
        )) ?? []
        return styled(unstyled, style: style, in: treeStore)
    }

    /// O(segments), so color changes recolor the finished layout instead of recomputing it.
    package nonisolated static func styled(
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

    /// Kind/age modes mirror the treemap; branch mode resolves the token. Not private so the legend can
    /// resolve fills for nodes without a rendered segment.
    package nonisolated static func resolvedFillRGB(
        for node: FileNodeRecord,
        token: SunburstColorToken,
        style: SunburstColorStyle
    ) -> SIMD3<Float>? {
        var rgb = semanticFillRGB(for: node, token: token, style: style)
        guard style.mode != .branch else { return rgb }
        // Only .kind and .age reach here, so the highlight-match predicate
        // is shared with the treemap unchanged.
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

    /// O(1) in every mode via the segment's token, so hover never walks ancestors or siblings.
    package nonisolated static func semanticFillRGB(
        for node: FileNodeRecord,
        token: SunburstColorToken,
        style: SunburstColorStyle
    ) -> SIMD3<Float> {
        switch style.mode {
        case .branch:
            return SunburstColorResolver.rgb(for: token, palette: style.palette.sunburst)
        case .kind:
            return style.catalog.rgb(for: node)
        case .age(let referenceDate):
            if FileKindClassifier.isLeafLike(node) {
                return style.palette.ageRGB(
                    AgeBucket.bucket(for: node.lastModified, reference: referenceDate)
                )
            }
            return FileKindCatalog.directoryRGB
        }
    }
}

private extension SunburstColorStyle.Mode {
    /// Shares the treemap's highlight predicate; only the `.age` date matters there, so `.branch` maps to `.kind`.
    var treemapColorMode: TreemapColorMode {
        switch self {
        case .age(let referenceDate): return .age(referenceDate: referenceDate)
        case .kind, .branch: return .kind
        }
    }
}
