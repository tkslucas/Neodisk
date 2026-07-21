//
//  PaneLayout.swift
//  Neodisk
//
//  Sizing policy for the workspace's user-resizable panes: per-pane bounds
//  and defaults, plus the geometry that keeps the map pane usable no matter
//  how the window and panes are arranged.
//

import Foundation

/// Per-pane sizing bounds and defaults. The static maxima describe how far a
/// pane may grow on a spacious window; `WorkspacePaneMetrics` additionally
/// caps them against the actual window so the map pane never collapses.
enum PaneLayout {
    static let splitterThickness = 8.0

    static let outlineDefaultWidth = 300.0
    static let outlineMinWidth = 240.0
    static let outlineMaxWidth = 600.0

    static let analysisDefaultWidth = 230.0
    static let analysisMinWidth = 200.0
    static let analysisMaxWidth = 340.0

    static let bottomOutlineDefaultHeight = 200.0
    static let bottomOutlineMinHeight = 120.0
    static let bottomOutlineMaxHeight = 440.0

    /// The map (treemap/sunburst) is a primary navigation surface; side-pane
    /// ranges shrink before its width goes below this.
    static let mapMinWidth = 300.0

    /// Minimum height for the map column above a bottom-docked outline:
    /// the breadcrumb bar plus a usable map.
    static let mapColumnMinHeight = 240.0

    static let sunburstLegendDefaultWidth = 340.0
    static let sunburstLegendMinWidth = 260.0
    static let sunburstLegendMaxWidth = 420.0

    /// Below this the rings are unreadable; the legend concedes and finally
    /// hides rather than squeeze the chart past it.
    static let sunburstChartMinWidth = 320.0
}

/// Effective pane sizes and drag ranges for one workspace layout pass.
///
/// Persisted pane sizes are clamped on read, never written back: a size that
/// no longer fits (smaller window, stale defaults entry) displays clamped and
/// comes back when room returns. Drag sessions start from the clamped value,
/// so the divider never jumps.
///
/// When the window can't honor both side panes at full size, the analysis
/// pane concedes first (down to its minimum), then the outline — the outline
/// is a primary navigation surface, the analysis pane is secondary. The
/// resolution is sequential, so the invariant "map ≥ `mapMinWidth`" holds at
/// every step: each pane's cap subtracts the other's already-resolved width.
struct WorkspacePaneMetrics: Equatable {
    var outlineWidth: Double
    var outlineRange: ClosedRange<Double>
    var analysisWidth: Double
    var analysisRange: ClosedRange<Double>
    var bottomOutlineHeight: Double
    var bottomOutlineRange: ClosedRange<Double>

    init(
        available: CGSize,
        showsLeadingOutline: Bool,
        showsAnalysis: Bool,
        storedOutlineWidth: Double,
        storedAnalysisWidth: Double,
        storedBottomOutlineHeight: Double
    ) {
        let splitter = PaneLayout.splitterThickness

        // Analysis resolves against the outline's stored (statically clamped)
        // width, then the outline against the analysis's resolved width.
        let outlineFootprint = showsLeadingOutline
            ? storedOutlineWidth.clamped(
                to: PaneLayout.outlineMinWidth...PaneLayout.outlineMaxWidth
            ) + splitter
            : 0

        let analysisCap = available.width - PaneLayout.mapMinWidth - outlineFootprint - splitter
        analysisRange = Self.range(
            min: PaneLayout.analysisMinWidth, max: PaneLayout.analysisMaxWidth, cap: analysisCap
        )
        analysisWidth = storedAnalysisWidth.clamped(to: analysisRange)

        let analysisFootprint = showsAnalysis ? analysisWidth + splitter : 0
        let outlineCap = available.width - PaneLayout.mapMinWidth - analysisFootprint - splitter
        outlineRange = Self.range(
            min: PaneLayout.outlineMinWidth, max: PaneLayout.outlineMaxWidth, cap: outlineCap
        )
        outlineWidth = storedOutlineWidth.clamped(to: outlineRange)

        let bottomCap = available.height - PaneLayout.mapColumnMinHeight - splitter
        bottomOutlineRange = Self.range(
            min: PaneLayout.bottomOutlineMinHeight,
            max: PaneLayout.bottomOutlineMaxHeight,
            cap: bottomCap
        )
        bottomOutlineHeight = storedBottomOutlineHeight.clamped(to: bottomOutlineRange)
    }

    /// A pane's drag range: the static bounds, with the maximum lowered to
    /// what the window can spare. At pathological sizes the cap can fall
    /// below the minimum; the minimum wins so the range stays valid — the
    /// window's own minimum size keeps that case out of reach in practice.
    private static func range(min lower: Double, max upper: Double, cap: Double) -> ClosedRange<Double> {
        lower...max(lower, min(upper, cap))
    }
}

/// The legend column inside the sunburst pane, resolved against the pane's
/// actual width with the same clamp-on-read policy as the workspace panes.
/// The legend concedes down to its minimum to keep the chart at
/// `sunburstChartMinWidth`; when even that doesn't fit, it hides entirely
/// (`width == nil`) and the chart takes the whole pane — a tiny window shows
/// a small chart, never a blank pane.
struct SunburstLegendMetrics: Equatable {
    /// Effective legend width; nil hides the legend (and its splitter).
    var width: Double?
    var range: ClosedRange<Double>

    init(availableWidth: Double, storedWidth: Double) {
        let cap = availableWidth - PaneLayout.sunburstChartMinWidth - PaneLayout.splitterThickness
        guard cap >= PaneLayout.sunburstLegendMinWidth else {
            width = nil
            range = PaneLayout.sunburstLegendMinWidth...PaneLayout.sunburstLegendMinWidth
            return
        }
        let upper = max(PaneLayout.sunburstLegendMinWidth, min(PaneLayout.sunburstLegendMaxWidth, cap))
        range = PaneLayout.sunburstLegendMinWidth...upper
        width = storedWidth.clamped(to: range)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
