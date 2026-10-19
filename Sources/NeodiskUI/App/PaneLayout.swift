import Foundation
import NeodiskAppModel

/// `WorkspacePaneMetrics` further caps the static maxima against the real window so the map never collapses.
enum PaneLayout {
    static let splitterThickness = 8.0

    /// Text panes scale all three bounds with the text scale, so larger text widens the pane instead of
    /// ellipsizing.

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

    // The map is graphics: its floors stay put at every text size, so larger text spends width on the text
    // panes.

    /// The map (treemap/sunburst) is a primary navigation surface; side-pane
    /// ranges shrink before its width goes below this.
    static let mapMinWidth = 300.0

    /// When docking would leave less, the pane floats over the map's trailing edge instead of squeezing it.
    static let mapMinWidthBesideAnalysis = 560.0

    /// Minimum height for the map column above a bottom-docked outline:
    /// the breadcrumb bar plus a usable map.
    static let mapColumnMinHeight = 240.0

    /// Below this the rings are unreadable; the legend concedes and finally
    /// hides rather than squeeze the chart past it.
    static let sunburstChartMinWidth = 320.0

    /// Grows slower than the panes since the map floor doesn't grow: at 200% text the widest layout needs
    /// 1_196pt and this gives 1_350, without demanding more than a laptop display shows.
    static func windowMinWidth(scale: Double = 1) -> Double { 900 * damped(scale) }
    static func windowMinHeight(scale: Double = 1) -> Double { 560 * damped(scale) }

    private static func damped(_ scale: Double) -> Double { 1 + (scale - 1) * 0.5 }
}

/// Sunburst always uses the bottom table to preserve chart width.
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

/// Persisted sizes are clamped on read, never written back, so they return when room does. The analysis
/// pane concedes first, then the outline; too narrow even for a minimum analysis pane, it floats over the map.
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

    /// At pathological sizes the cap can fall below the minimum; the minimum wins so the range stays valid.
    private static func range(min lower: Double, max upper: Double, cap: Double) -> ClosedRange<Double> {
        lower...max(lower, min(upper, cap))
    }
}

/// Concedes to its minimum to keep the chart at `sunburstChartMinWidth`, then hides (`width == nil`):
/// a tiny window shows a small chart, never a blank pane.
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
