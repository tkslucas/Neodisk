// WorkspacePaneMetrics keeps the map pane usable: widths capped to the window, side panes always docked and
// narrowing at large text rather than covering the map, and valid ranges at pathological sizes.

import Foundation
import SwiftUI
import Testing
@testable import NeodiskUI
@testable import NeodiskAppModel

@Suite struct PaneLayoutTests {
    private func metrics(
        width: Double = 1600,
        height: Double = 900,
        showsLeadingOutline: Bool = true,
        showsAnalysis: Bool = true,
        outline: Double = PaneLayout.outlineDefaultWidth(),
        analysis: Double = PaneLayout.analysisDefaultWidth(),
        bottom: Double = PaneLayout.bottomOutlineDefaultHeight()
    ) -> WorkspacePaneMetrics {
        WorkspacePaneMetrics(
            available: CGSize(width: width, height: height),
            showsLeadingOutline: showsLeadingOutline,
            showsAnalysis: showsAnalysis,
            storedOutlineWidth: outline,
            storedAnalysisWidth: analysis,
            storedBottomOutlineHeight: bottom
        )
    }

    private func mapWidth(_ m: WorkspacePaneMetrics) -> Double {
        // Leading outline + splitter, map, splitter + analysis.
        1_600 - m.outlineWidth - m.analysisWidth - 2 * PaneLayout.splitterThickness
    }

    @Test func spaciousWindowHonorsStoredSizesAndStaticBounds() {
        let m = metrics(outline: 420, analysis: 300, bottom: 250)
        #expect(m.outlineWidth == 420)
        #expect(m.analysisWidth == 300)
        #expect(m.bottomOutlineHeight == 250)
        #expect(m.outlineRange == PaneLayout.outlineMinWidth()...PaneLayout.outlineMaxWidth())
        #expect(m.analysisRange == PaneLayout.analysisMinWidth()...PaneLayout.analysisMaxWidth())
        #expect(
            m.bottomOutlineRange
                == PaneLayout.bottomOutlineMinHeight()...PaneLayout.bottomOutlineMaxHeight()
        )
    }

    @Test func minimumWindowWithMaxedPanesKeepsMapAtMinimum() {
        // The old bug: 600 + 340 + 16 = 956 fixed points in a 900-point
        // window collapsed the map to zero.
        let m = metrics(
            width: 900,
            outline: PaneLayout.outlineMaxWidth(),
            analysis: PaneLayout.analysisMaxWidth()
        )
        let map = 900 - m.outlineWidth - m.analysisWidth - 2 * PaneLayout.splitterThickness
        #expect(map >= PaneLayout.mapMinWidth)
    }

    @Test func narrowWindowDocksAnalysisAtItsMinimum() {
        // 900 − 300 map − 16 splitters leaves 584: the analysis pane concedes to its minimum, the outline takes
        // the rest, and the map keeps its own.
        let m = metrics(
            width: 900,
            outline: PaneLayout.outlineMaxWidth(),
            analysis: PaneLayout.analysisMaxWidth()
        )
        #expect(m.analysisWidth == PaneLayout.analysisMinWidth())
        #expect(m.outlineWidth == 900 - PaneLayout.mapMinWidth - m.analysisWidth - 2 * PaneLayout.splitterThickness)
    }

    /// F36: at 200% in a 1_350-point window with the file list on the left, the panes' text-size minimums
    /// (480 + 400) don't fit beside the map; they narrow together and the map keeps its minimum.
    @Test func largeTextNarrowsTheSidePanesInsteadOfCoveringTheMap() {
        let detail = 1_350 - PaneLayout.sidebarIdealWidth(scale: 2) - 10
        let m = WorkspacePaneMetrics(
            available: CGSize(width: detail, height: 800),
            showsLeadingOutline: true,
            showsAnalysis: true,
            storedOutlineWidth: PaneLayout.outlineDefaultWidth(scale: 2),
            storedAnalysisWidth: PaneLayout.analysisDefaultWidth(scale: 2),
            storedBottomOutlineHeight: PaneLayout.bottomOutlineDefaultHeight(scale: 2),
            textScale: 2
        )
        let map = detail - m.outlineWidth - m.analysisWidth - 2 * PaneLayout.splitterThickness
        #expect(map >= PaneLayout.mapMinWidth - 0.001)
        #expect(m.outlineRange.lowerBound < PaneLayout.outlineMinWidth(scale: 2))
        #expect(m.analysisRange.lowerBound < PaneLayout.analysisMinWidth(scale: 2))
        // Never below their 100% minimums.
        #expect(m.outlineRange.lowerBound >= PaneLayout.outlineMinWidth())
        #expect(m.analysisRange.lowerBound >= PaneLayout.analysisMinWidth())
    }

    @Test func minimumsShrinkOnlyWhenTheyDontFit() {
        let roomy = WorkspacePaneMetrics.minimums(
            available: 2_000, showsLeadingOutline: true, showsAnalysis: true, textScale: 2
        )
        #expect(roomy.outline == PaneLayout.outlineMinWidth(scale: 2))
        #expect(roomy.analysis == PaneLayout.analysisMinWidth(scale: 2))
        // Without the outline, the analysis pane alone fits beside the map.
        let alone = WorkspacePaneMetrics.minimums(
            available: 840, showsLeadingOutline: false, showsAnalysis: true, textScale: 2
        )
        #expect(alone.analysis == PaneLayout.analysisMinWidth(scale: 2))
        // Smaller text keeps its own, smaller minimums even in a tiny window.
        let small = WorkspacePaneMetrics.minimums(
            available: 300, showsLeadingOutline: true, showsAnalysis: true, textScale: 0.85
        )
        #expect(small.outline == PaneLayout.outlineMinWidth(scale: 0.85))
        #expect(small.analysis == PaneLayout.analysisMinWidth(scale: 0.85))
    }

    @Test func hiddenAnalysisPaneFreesItsFootprintForTheOutline() {
        // Docked at 1_100, the analysis pane caps the outline's drag range.
        let shown = metrics(width: 1_100)
        let hidden = metrics(width: 1_100, showsAnalysis: false)
        #expect(hidden.outlineRange.upperBound > shown.outlineRange.upperBound)
    }

    @Test func hiddenOutlineGivesTheAnalysisPaneItsRoom() {
        let shown = metrics(width: 800, outline: PaneLayout.outlineMaxWidth())
        let hidden = metrics(
            width: 800, showsLeadingOutline: false, outline: PaneLayout.outlineMaxWidth()
        )
        #expect(hidden.analysisRange.upperBound > shown.analysisRange.upperBound)
    }

    @Test func shortWindowCapsBottomOutline() {
        // 560 (window minimum) − map column 240 − splitter 8 = 312 < 440.
        let m = metrics(height: 560, bottom: PaneLayout.bottomOutlineMaxHeight())
        let cap = 560 - PaneLayout.mapColumnMinHeight - PaneLayout.splitterThickness
        #expect(m.bottomOutlineRange.upperBound == cap)
        #expect(m.bottomOutlineHeight == cap)
    }

    @Test func outOfRangeStoredValuesClampOnRead() {
        // Stale defaults entries (hand-edited, or written before bounds
        // changed) must not render out of range.
        let m = metrics(outline: 5_000, analysis: 10, bottom: -3)
        #expect(m.outlineWidth == PaneLayout.outlineMaxWidth())
        #expect(m.analysisWidth == PaneLayout.analysisMinWidth())
        #expect(m.bottomOutlineHeight == PaneLayout.bottomOutlineMinHeight())
    }

    @Test func pathologicalSizesStillYieldValidRanges() {
        // Below every pane's minimum the range degenerates to min...min
        // rather than crashing on an inverted ClosedRange.
        let m = metrics(width: 100, height: 50)
        #expect(m.outlineRange == PaneLayout.outlineMinWidth()...PaneLayout.outlineMinWidth())
        #expect(m.analysisRange == PaneLayout.analysisMinWidth()...PaneLayout.analysisMinWidth())
        #expect(
            m.bottomOutlineRange
                == PaneLayout.bottomOutlineMinHeight()...PaneLayout.bottomOutlineMinHeight()
        )
    }

    @Test func windowMinimumsAccommodateAllPaneMinimums() {
        // At the window's minimum size every pane at its minimum plus the map minimum still fits.
        let widthFloor = PaneLayout.outlineMinWidth() + PaneLayout.analysisMinWidth()
            + 2 * PaneLayout.splitterThickness + PaneLayout.mapMinWidth
        let heightFloor = PaneLayout.bottomOutlineMinHeight() + PaneLayout.splitterThickness
            + PaneLayout.mapColumnMinHeight
        #expect(widthFloor <= PaneLayout.windowMinWidth())
        #expect(heightFloor <= PaneLayout.windowMinHeight())
    }

    @Test func minimumWindowDocksTheStatisticsPanelBesideTheMap() {
        for step in TextScale.steps where PaneLayout.windowMinWidth(scale: step) < 1_350 {
            // The detail column beside the widest sidebar, as the split view lays it out.
            let detail = PaneLayout.windowMinWidth(scale: step) - PaneLayout.sidebarMaxWidth(scale: step) - 10
            let m = WorkspacePaneMetrics(
                available: CGSize(width: detail, height: 700),
                showsLeadingOutline: false,
                showsAnalysis: true,
                storedOutlineWidth: PaneLayout.outlineDefaultWidth(scale: step),
                storedAnalysisWidth: PaneLayout.analysisDefaultWidth(scale: step),
                storedBottomOutlineHeight: PaneLayout.bottomOutlineDefaultHeight(scale: step),
                textScale: step
            )
            // The panel at its full text-size minimum still leaves the map a comfortable width.
            #expect(m.analysisRange.lowerBound == PaneLayout.analysisMinWidth(scale: step), "text scale \(step)")
            let map = detail - m.analysisRange.lowerBound - PaneLayout.splitterThickness
            #expect(map >= PaneLayout.mapMinWidthBesideAnalysis, "text scale \(step)")
        }
    }

    @Test func windowMinimumNeverOutgrowsTheScreen() {
        let laptop = CGSize(width: 1440, height: 875)
        let largest = PaneLayout.windowMinSize(scale: 2, screen: laptop)
        #expect(largest.width <= laptop.width - 40 && largest.height <= laptop.height - 100)
        // A big display keeps the full minimum.
        #expect(PaneLayout.windowMinSize(scale: 2, screen: CGSize(width: 2560, height: 1400))
            == CGSize(width: PaneLayout.windowMinWidth(scale: 2), height: PaneLayout.windowMinHeight(scale: 2)))
    }

    @Test func firstWindowTakesMostOfTheScreenWithinBounds() {
        let laptop = PaneLayout.defaultWindowSize(screen: CGSize(width: 1470, height: 920))
        #expect(laptop.width == 1250 && laptop.height == 782)
        let large = PaneLayout.defaultWindowSize(screen: CGSize(width: 3000, height: 1600))
        #expect(large == CGSize(width: 1600, height: 1000))
        let small = PaneLayout.defaultWindowSize(screen: CGSize(width: 1024, height: 640))
        #expect(small.width == PaneLayout.windowMinWidth() && small.height == PaneLayout.windowMinHeight())
    }
}

@Suite struct SunburstLegendMetricsTests {
    @Test func spaciousPaneHonorsStoredWidthAndStaticBounds() {
        let m = SunburstLegendMetrics(availableWidth: 1_200, storedWidth: 380)
        #expect(m.width == 380)
        #expect(
            m.range == PaneLayout.sunburstLegendMinWidth()...PaneLayout.sunburstLegendMaxWidth()
        )
    }

    @Test func narrowPaneCapsLegendToKeepChartUsable() {
        let available = 700.0
        let m = SunburstLegendMetrics(
            availableWidth: available, storedWidth: PaneLayout.sunburstLegendMaxWidth()
        )
        let chart = available - m.width! - PaneLayout.splitterThickness
        #expect(chart >= PaneLayout.sunburstChartMinWidth)
    }

    @Test func tooNarrowForBothHidesLegendEntirely() {
        // The old bug: a fixed 340-point legend in a ~330-point pane pushed
        // the chart to zero width — nothing visible at all.
        let m = SunburstLegendMetrics(availableWidth: 330, storedWidth: 340)
        #expect(m.width == nil)
    }

    @Test func legendReturnsOnceThereIsRoomAgain() {
        let threshold = PaneLayout.sunburstChartMinWidth
            + PaneLayout.splitterThickness + PaneLayout.sunburstLegendMinWidth()
        #expect(SunburstLegendMetrics(availableWidth: threshold - 1, storedWidth: 340).width == nil)
        #expect(SunburstLegendMetrics(availableWidth: threshold, storedWidth: 340).width != nil)
    }

    @Test func outOfRangeStoredWidthClampsOnRead() {
        let m = SunburstLegendMetrics(availableWidth: 1_200, storedWidth: 5_000)
        #expect(m.width == PaneLayout.sunburstLegendMaxWidth())
    }
}

@Suite @MainActor struct PaneSplitterMappingTests {
    private func splitter(_ edge: Edge) -> PaneSplitter {
        PaneSplitter(size: .constant(300), range: 100...500, defaultSize: 300, paneEdge: edge)
    }

    @Test func edgesMapToOrientationAndDragSign() {
        // A drag right/down is a positive raw delta; it grows the pane that
        // sits on the leading/top side and shrinks the trailing/bottom one.
        #expect(splitter(.leading).orientation == .column)
        #expect(splitter(.leading).deltaSign == 1)
        #expect(splitter(.trailing).orientation == .column)
        #expect(splitter(.trailing).deltaSign == -1)
        #expect(splitter(.top).orientation == .row)
        #expect(splitter(.top).deltaSign == 1)
        #expect(splitter(.bottom).orientation == .row)
        #expect(splitter(.bottom).deltaSign == -1)
    }

    @Test func mouseDragEndsExactlyOnceOnMouseUp() throws {
        let view = SplitterNSView(orientation: .column)
        var beganCount = 0
        var endedCount = 0
        view.onDragBegan = { beganCount += 1 }
        view.onDragEnded = { endedCount += 1 }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 1))
        #expect(beganCount == 1)
        #expect(endedCount == 0)

        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1))
        #expect(endedCount == 1)

        // Stray mouse-up events are not resize commits.
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1))
        #expect(endedCount == 1)
    }

    @Test func doubleClickResetsWithoutEndingADrag() throws {
        let view = SplitterNSView(orientation: .column)
        var resetCount = 0
        var endedCount = 0
        view.onReset = { resetCount += 1 }
        view.onDragEnded = { endedCount += 1 }

        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 2))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 2))

        #expect(resetCount == 1)
        #expect(endedCount == 0)
    }

    @Test func keyboardStepEndsImmediately() throws {
        let view = SplitterNSView(orientation: .column)
        var beganCount = 0
        var deltas: [CGFloat] = []
        var endedCount = 0
        view.onDragBegan = { beganCount += 1 }
        view.onDrag = { deltas.append($0) }
        view.onDragEnded = { endedCount += 1 }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}",
            isARepeat: false,
            keyCode: 124
        ))
        view.keyDown(with: event)

        #expect(beganCount == 1)
        #expect(deltas == [SplitterNSView.keyboardStep])
        #expect(endedCount == 1)
    }

    private func mouseEvent(type: NSEvent.EventType, clickCount: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        ))
    }
}
