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

    /// The map's width beside the docked statistics panel at the window's minimum size: room to read it, not
    /// just to keep it.
    static let mapMinWidthBesideAnalysis = 560.0

    /// Minimum height for the map column above a bottom-docked outline:
    /// the breadcrumb bar plus a usable map.
    static let mapColumnMinHeight = 240.0

    /// Below this the rings are unreadable; the legend concedes and finally
    /// hides rather than squeeze the chart past it.
    static let sunburstChartMinWidth = 320.0

    /// The locations sidebar's column, which the window's minimum includes.
    static func sidebarMinWidth(scale: Double = 1) -> Double { 210 * scale }
    static func sidebarIdealWidth(scale: Double = 1) -> Double { 250 * scale }
    static func sidebarMaxWidth(scale: Double = 1) -> Double { 320 * scale }

    /// The smallest window docks the statistics panel beside a comfortable map and bottom file list (sidebar
    /// shown at any width), up to 1_350pt, what a laptop display shows: past that (large text) the side panes
    /// narrow below their text-size minimums instead (see WorkspacePaneMetrics).
    static func windowMinWidth(scale: Double = 1) -> Double {
        // +10: the split view adds its divider and a few points to the sidebar column.
        let docks = sidebarMaxWidth(scale: scale) + 10 + mapMinWidthBesideAnalysis + splitterThickness
            + analysisMinWidth(scale: scale)
        return max(900 * damped(scale), min(docks.rounded(.up), 1_350))
    }
    static func windowMinHeight(scale: Double = 1) -> Double { 560 * damped(scale) }

    /// The content minimum, never larger than the screen shows (its visible frame less the title bar and
    /// toolbar): at large text on a small display the panes squeeze rather than the window running off-screen.
    static func windowMinSize(scale: Double = 1, screen: CGSize?) -> CGSize {
        let minimum = CGSize(width: windowMinWidth(scale: scale), height: windowMinHeight(scale: scale))
        guard let screen else { return minimum }
        return CGSize(
            width: min(minimum.width, screen.width - 40),
            height: min(minimum.height, screen.height - 100)
        )
    }

    /// A first window takes most of the screen, within bounds where every pane reads well; later launches
    /// restore the user's own size.
    static func defaultWindowSize(screen: CGSize?) -> CGSize {
        let visible = screen ?? CGSize(width: 1440, height: 900)
        return CGSize(
            width: (visible.width * 0.85).clamped(to: windowMinWidth()...1_600).rounded(),
            height: (visible.height * 0.85).clamped(to: windowMinHeight()...1_000).rounded()
        )
    }

    private static func damped(_ scale: Double) -> Double { 1 + (scale - 1) * 0.5 }
}

/// Persisted sizes are clamped on read, never written back, so they return when room does. Side panes always
/// dock (a pane over the map hid it, and its edge couldn't be dragged): the analysis pane concedes first, then
/// the outline; where even their minimums leave the map less than `mapMinWidth` (large text in a laptop-sized
/// window), those minimums shrink together toward their 100% sizes, text truncating before the map goes.
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
        storedBottomOutlineHeight: Double,
        textScale: Double = 1
    ) {
        let splitter = PaneLayout.splitterThickness
        let minimums = Self.minimums(
            available: available.width,
            showsLeadingOutline: showsLeadingOutline,
            showsAnalysis: showsAnalysis,
            textScale: textScale
        )

        // Analysis resolves against the outline's stored (statically clamped)
        // width, then the outline against the analysis's resolved width.
        let outlineFootprint = showsLeadingOutline
            ? storedOutlineWidth.clamped(
                to: minimums.outline ... max(minimums.outline, PaneLayout.outlineMaxWidth(scale: textScale))
            ) + splitter
            : 0

        let analysisMin = minimums.analysis
        let analysisCap = available.width - PaneLayout.mapMinWidth - outlineFootprint - splitter
        analysisRange = Self.range(
            min: analysisMin,
            max: PaneLayout.analysisMaxWidth(scale: textScale),
            cap: analysisCap
        )
        analysisWidth = storedAnalysisWidth.clamped(to: analysisRange)

        let analysisFootprint = showsAnalysis ? analysisWidth + splitter : 0
        let outlineCap = available.width - PaneLayout.mapMinWidth - analysisFootprint - splitter
        outlineRange = Self.range(
            min: minimums.outline,
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

    /// The side panes' minimums: their text-size ones while those leave the map `mapMinWidth`, else scaled down
    /// together to fit, but never below their 100% sizes (a smaller text size keeps its own, smaller ones).
    static func minimums(
        available: Double,
        showsLeadingOutline: Bool,
        showsAnalysis: Bool,
        textScale: Double
    ) -> (outline: Double, analysis: Double) {
        let outline = PaneLayout.outlineMinWidth(scale: textScale)
        let analysis = PaneLayout.analysisMinWidth(scale: textScale)
        let outlineFloor = min(outline, PaneLayout.outlineMinWidth())
        let analysisFloor = min(analysis, PaneLayout.analysisMinWidth())
        let splitters = Double((showsLeadingOutline ? 1 : 0) + (showsAnalysis ? 1 : 0)) * PaneLayout.splitterThickness
        let room = available - PaneLayout.mapMinWidth - splitters
        let wanted = (showsLeadingOutline ? outline : 0) + (showsAnalysis ? analysis : 0)
        guard wanted > room, wanted > 0 else { return (outline, analysis) }
        let fit = max(0, room) / wanted
        return (max(outlineFloor, outline * fit), max(analysisFloor, analysis * fit))
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
