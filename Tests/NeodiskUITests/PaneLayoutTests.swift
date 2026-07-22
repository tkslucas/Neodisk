//
//  PaneLayoutTests.swift
//  Neodisk
//
//  WorkspacePaneMetrics keeps the map pane usable: side-pane widths and drag
//  ranges are capped against the actual window, the analysis pane concedes
//  before the outline, ranges stay valid at pathological sizes, and stored
//  sizes pass through untouched when there is room.
//

import Foundation
import SwiftUI
import Testing
@testable import NeodiskUI

@Suite struct PaneLayoutTests {
    private func metrics(
        width: Double = 1600,
        height: Double = 900,
        showsLeadingOutline: Bool = true,
        showsAnalysis: Bool = true,
        outline: Double = PaneLayout.outlineDefaultWidth,
        analysis: Double = PaneLayout.analysisDefaultWidth,
        bottom: Double = PaneLayout.bottomOutlineDefaultHeight
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

    @Test func treemapFileListFollowsDockPosition() {
        let leading = WorkspaceFileListVisibility(
            viewMode: .treemap,
            treemapPosition: .leading,
            showsBelowSunburst: true
        )
        let bottom = WorkspaceFileListVisibility(
            viewMode: .treemap,
            treemapPosition: .bottom,
            showsBelowSunburst: false
        )

        #expect(leading.showsLeading)
        #expect(!leading.showsBottom)
        #expect(!bottom.showsLeading)
        #expect(bottom.showsBottom)
    }

    @Test func sunburstFileListIsBottomOnlyAndOptIn() {
        for position in OutlinePosition.allCases {
            let hidden = WorkspaceFileListVisibility(
                viewMode: .sunburst,
                treemapPosition: position,
                showsBelowSunburst: false
            )
            let shown = WorkspaceFileListVisibility(
                viewMode: .sunburst,
                treemapPosition: position,
                showsBelowSunburst: true
            )

            #expect(!hidden.showsLeading)
            #expect(!hidden.showsBottom)
            #expect(!shown.showsLeading)
            #expect(shown.showsBottom)
        }
    }

    @Test func spaciousWindowHonorsStoredSizesAndStaticBounds() {
        let m = metrics(outline: 420, analysis: 300, bottom: 250)
        #expect(m.outlineWidth == 420)
        #expect(m.analysisWidth == 300)
        #expect(m.bottomOutlineHeight == 250)
        #expect(m.outlineRange == PaneLayout.outlineMinWidth...PaneLayout.outlineMaxWidth)
        #expect(m.analysisRange == PaneLayout.analysisMinWidth...PaneLayout.analysisMaxWidth)
        #expect(
            m.bottomOutlineRange
                == PaneLayout.bottomOutlineMinHeight...PaneLayout.bottomOutlineMaxHeight
        )
    }

    @Test func minimumWindowWithMaxedPanesKeepsMapAtMinimum() {
        // The old bug: 600 + 340 + 16 = 956 fixed points in a 900-point
        // window collapsed the map to zero.
        let m = metrics(
            width: 900,
            outline: PaneLayout.outlineMaxWidth,
            analysis: PaneLayout.analysisMaxWidth
        )
        let map = 900 - m.outlineWidth - m.analysisWidth - 2 * PaneLayout.splitterThickness
        #expect(map >= PaneLayout.mapMinWidth)
    }

    @Test func analysisPaneConcedesBeforeOutline() {
        let m = metrics(
            width: 900,
            outline: PaneLayout.outlineMaxWidth,
            analysis: PaneLayout.analysisMaxWidth
        )
        #expect(m.analysisWidth == PaneLayout.analysisMinWidth)
        #expect(m.outlineWidth > PaneLayout.outlineMinWidth)
    }

    @Test func hiddenAnalysisPaneFreesItsFootprintForTheOutline() {
        let shown = metrics(width: 900, outline: PaneLayout.outlineMaxWidth)
        let hidden = metrics(
            width: 900, showsAnalysis: false, outline: PaneLayout.outlineMaxWidth
        )
        #expect(hidden.outlineRange.upperBound > shown.outlineRange.upperBound)
    }

    @Test func hiddenOutlineFreesItsFootprintForAnalysis() {
        let shown = metrics(width: 760, outline: PaneLayout.outlineMaxWidth)
        let hidden = metrics(
            width: 760, showsLeadingOutline: false, outline: PaneLayout.outlineMaxWidth
        )
        #expect(hidden.analysisRange.upperBound > shown.analysisRange.upperBound)
    }

    @Test func shortWindowCapsBottomOutline() {
        // 560 (window minimum) − map column 240 − splitter 8 = 312 < 440.
        let m = metrics(height: 560, bottom: PaneLayout.bottomOutlineMaxHeight)
        let cap = 560 - PaneLayout.mapColumnMinHeight - PaneLayout.splitterThickness
        #expect(m.bottomOutlineRange.upperBound == cap)
        #expect(m.bottomOutlineHeight == cap)
    }

    @Test func outOfRangeStoredValuesClampOnRead() {
        // Stale defaults entries (hand-edited, or written before bounds
        // changed) must not render out of range.
        let m = metrics(outline: 5_000, analysis: 10, bottom: -3)
        #expect(m.outlineWidth == PaneLayout.outlineMaxWidth)
        #expect(m.analysisWidth == PaneLayout.analysisMinWidth)
        #expect(m.bottomOutlineHeight == PaneLayout.bottomOutlineMinHeight)
    }

    @Test func pathologicalSizesStillYieldValidRanges() {
        // Below every pane's minimum the range degenerates to min...min
        // rather than crashing on an inverted ClosedRange.
        let m = metrics(width: 100, height: 50)
        #expect(m.outlineRange == PaneLayout.outlineMinWidth...PaneLayout.outlineMinWidth)
        #expect(m.analysisRange == PaneLayout.analysisMinWidth...PaneLayout.analysisMinWidth)
        #expect(
            m.bottomOutlineRange
                == PaneLayout.bottomOutlineMinHeight...PaneLayout.bottomOutlineMinHeight
        )
    }

    @Test func windowMinimumsAccommodateAllPaneMinimums() {
        // The guarantee behind "the minimum always wins": at the window's
        // minimum size (900×560, ContentView) even every pane at its minimum
        // plus the map minimum still fits.
        let widthFloor = PaneLayout.outlineMinWidth + PaneLayout.analysisMinWidth
            + 2 * PaneLayout.splitterThickness + PaneLayout.mapMinWidth
        let heightFloor = PaneLayout.bottomOutlineMinHeight + PaneLayout.splitterThickness
            + PaneLayout.mapColumnMinHeight
        #expect(widthFloor <= 900)
        #expect(heightFloor <= 560)
    }
}

@Suite struct SunburstLegendMetricsTests {
    @Test func spaciousPaneHonorsStoredWidthAndStaticBounds() {
        let m = SunburstLegendMetrics(availableWidth: 1_200, storedWidth: 380)
        #expect(m.width == 380)
        #expect(
            m.range == PaneLayout.sunburstLegendMinWidth...PaneLayout.sunburstLegendMaxWidth
        )
    }

    @Test func narrowPaneCapsLegendToKeepChartUsable() {
        let available = 700.0
        let m = SunburstLegendMetrics(
            availableWidth: available, storedWidth: PaneLayout.sunburstLegendMaxWidth
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
            + PaneLayout.splitterThickness + PaneLayout.sunburstLegendMinWidth
        #expect(SunburstLegendMetrics(availableWidth: threshold - 1, storedWidth: 340).width == nil)
        #expect(SunburstLegendMetrics(availableWidth: threshold, storedWidth: 340).width != nil)
    }

    @Test func outOfRangeStoredWidthClampsOnRead() {
        let m = SunburstLegendMetrics(availableWidth: 1_200, storedWidth: 5_000)
        #expect(m.width == PaneLayout.sunburstLegendMaxWidth)
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
}
