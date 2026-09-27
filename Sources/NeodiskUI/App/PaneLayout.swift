//
//  PaneLayout.swift
//  Neodisk
//
//  Sizing policy for the workspace's user-resizable panes: per-pane bounds
//  and defaults, plus the geometry that keeps the map pane usable no matter
//  how the window and panes are arranged.
//

import Foundation
import NeodiskAppModel

/// Per-pane sizing bounds and defaults. The static maxima describe how far a
/// pane may grow on a spacious window; `WorkspacePaneMetrics` additionally
/// caps them against the actual window so the map pane never collapses.
enum PaneLayout {
    static let splitterThickness = 8.0

    /// Every pane that carries text is sized for the workspace text scale
    /// (see TextScale), so a larger text size widens the pane instead of
    /// ellipsizing every name in it. All three bounds scale together —
    /// a pane whose minimum lagged its text would just be a narrower pane.

    static func outlineDefaultWidth(scale: Double = 1) -> Double { 300 * scale }
    static func outlineMinWidth(scale: Double = 1) -> Double { 240 * scale }
    static func outlineMaxWidth(scale: Double = 1) -> Double { 600 * scale }

    static func analysisDefaultWidth(scale: Double = 1) -> Double { 230 * scale }
    static func analysisMinWidth(scale: Double = 1) -> Double { 200 * scale }
    static func analysisMaxWidth(scale: Double = 1) -> Double { 340 * scale }

    static func bottomOutlineDefaultHeight(scale: Double = 1) -> Double { 200 * scale }
    static func bottomOutlineMinHeight(scale: Double = 1) -> Double { 120 * scale }
    static func bottomOutlineMaxHeight(scale: Double = 1) -> Double { 440 * scale }

    static func sunburstLegendDefaultWidth(scale: Double = 1) -> Double { 340 * scale }
    static func sunburstLegendMinWidth(scale: Double = 1) -> Double { 260 * scale }
    static func sunburstLegendMaxWidth(scale: Double = 1) -> Double { 420 * scale }

    // The map is graphics, not text. Its floors stay put at every text
    // size, so a larger size spends the window's width on the panes that
    // actually carry the text.

    /// The map (treemap/sunburst) is a primary navigation surface; side-pane
    /// ranges shrink before its width goes below this.
    static let mapMinWidth = 300.0

    /// Narrowest map the analysis pane may dock beside. When docking it
    /// (even at its minimum width) would leave less, the pane floats over
    /// the map's trailing edge instead of squeezing it.
    static let mapMinWidthBesideAnalysis = 560.0

    /// Minimum height for the map column above a bottom-docked outline:
    /// the breadcrumb bar plus a usable map.
    static let mapColumnMinHeight = 240.0

    /// Below this the rings are unreadable; the legend concedes and finally
    /// hides rather than squeeze the chart past it.
    static let sunburstChartMinWidth = 320.0

    /// The window's own minimum. It grows more slowly than the panes do,
    /// because the map's floor above does not grow at all: at 200% text the
    /// widest arrangement (both side panes at their minimum plus a minimum
    /// map) needs 1_196pt and this gives 1_350 — room to spare, without
    /// demanding a window size a laptop display can't show.
    static func windowMinWidth(scale: Double = 1) -> Double { 900 * damped(scale) }
    static func windowMinHeight(scale: Double = 1) -> Double { 560 * damped(scale) }

    private static func damped(_ scale: Double) -> Double { 1 + (scale - 1) * 0.5 }
}

/// Which form of the shared file list belongs in the current workspace.
/// Treemap follows its left/bottom docking preference; Sunburst has a
/// separate opt-in and always uses the bottom table to preserve chart width.
struct WorkspaceFileListVisibility: Equatable {
    let showsLeading: Bool
    let showsBottom: Bool

    init(
        viewMode: VizViewMode,
        treemapPosition: OutlinePosition,
        showsBelowSunburst: Bool
    ) {
        switch viewMode {
        case .treemap:
            showsLeading = treemapPosition == .leading
            showsBottom = treemapPosition == .bottom
        case .sunburst:
            showsLeading = false
            showsBottom = showsBelowSunburst
        }
    }
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
///
/// On a window too narrow for the map to stay comfortable beside even a
/// minimum-width analysis pane (`mapMinWidthBesideAnalysis`), the analysis
/// pane floats over the map instead of docking: the map and outline lay out
/// as if it were hidden.
struct WorkspacePaneMetrics: Equatable {
    var outlineWidth: Double
    var outlineRange: ClosedRange<Double>
    var analysisWidth: Double
    var analysisRange: ClosedRange<Double>
    /// The analysis pane overlays the map rather than taking room from it.
    var analysisFloats: Bool
    var bottomOutlineHeight: Double
    var bottomOutlineRange: ClosedRange<Double>

    init(
        available: CGSize,
        showsLeadingOutline: Bool,
        showsAnalysis: Bool,
        storedOutlineWidth: Double,
        storedAnalysisWidth: Double,
        storedBottomOutlineHeight: Double,
        textScale: Double = 1
    ) {
        let splitter = PaneLayout.splitterThickness

        // Analysis resolves against the outline's stored (statically clamped)
        // width, then the outline against the analysis's resolved width.
        let outlineFootprint = showsLeadingOutline
            ? storedOutlineWidth.clamped(
                to: PaneLayout.outlineMinWidth(scale: textScale) ...
                    PaneLayout.outlineMaxWidth(scale: textScale)
            ) + splitter
            : 0

        let analysisMin = PaneLayout.analysisMinWidth(scale: textScale)
        analysisFloats = available.width - outlineFootprint - analysisMin - splitter
            < PaneLayout.mapMinWidthBesideAnalysis

        // Docked, the pane gives way to the map; floating, only to the
        // window's own edge.
        let analysisCap = analysisFloats
            ? available.width - splitter
            : available.width - PaneLayout.mapMinWidth - outlineFootprint - splitter
        analysisRange = Self.range(
            min: analysisMin,
            max: PaneLayout.analysisMaxWidth(scale: textScale),
            cap: analysisCap
        )
        analysisWidth = storedAnalysisWidth.clamped(to: analysisRange)

        let analysisFootprint = showsAnalysis && !analysisFloats ? analysisWidth + splitter : 0
        let outlineCap = available.width - PaneLayout.mapMinWidth - analysisFootprint - splitter
        outlineRange = Self.range(
            min: PaneLayout.outlineMinWidth(scale: textScale),
            max: PaneLayout.outlineMaxWidth(scale: textScale),
            cap: outlineCap
        )
        outlineWidth = storedOutlineWidth.clamped(to: outlineRange)

        let bottomCap = available.height - PaneLayout.mapColumnMinHeight - splitter
        bottomOutlineRange = Self.range(
            min: PaneLayout.bottomOutlineMinHeight(scale: textScale),
            max: PaneLayout.bottomOutlineMaxHeight(scale: textScale),
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

    init(availableWidth: Double, storedWidth: Double, textScale: Double = 1) {
        let minimum = PaneLayout.sunburstLegendMinWidth(scale: textScale)
        let cap = availableWidth - PaneLayout.sunburstChartMinWidth - PaneLayout.splitterThickness
        guard cap >= minimum else {
            width = nil
            range = minimum...minimum
            return
        }
        let upper = max(minimum, min(PaneLayout.sunburstLegendMaxWidth(scale: textScale), cap))
        range = minimum...upper
        width = storedWidth.clamped(to: range)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
