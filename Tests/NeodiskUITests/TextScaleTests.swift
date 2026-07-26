//
//  TextScaleTests.swift
//  Neodisk
//
//  The workspace text scale: the step ladder ⌘+/⌘− walk, the snapping every
//  stored value passes through, and the layout consequences — panes widen
//  with the text, the window minimum still holds both pane minimums plus a
//  usable map, and the treemap's label gates move with the label size.
//

import Foundation
import SwiftUI
import Testing
@testable import NeodiskUI

@Suite struct TextScaleTests {
    @Test func stepsAreSortedAndContainTheStandardSize() {
        #expect(TextScale.steps == TextScale.steps.sorted())
        #expect(TextScale.steps.contains(TextScale.standard))
    }

    @Test func snappingPullsArbitraryValuesOntoTheLadder() {
        for step in TextScale.steps {
            #expect(TextScale.snapped(step) == step)
        }
        // A hand-edited preference, or one written by a build with a
        // different ladder, still lands on a listed size.
        #expect(TextScale.snapped(1.02) == 1.0)
        #expect(TextScale.snapped(1.21) == 1.15)
        #expect(TextScale.snapped(-4) == TextScale.steps.first)
        #expect(TextScale.snapped(99) == TextScale.steps.last)
    }

    @Test func zoomingWalksTheLadderAndStopsAtBothEnds() {
        var scale = TextScale.steps.first!
        var visited = [scale]
        while let next = TextScale.larger(than: scale) {
            scale = next
            visited.append(scale)
        }
        #expect(visited == TextScale.steps)
        #expect(TextScale.larger(than: TextScale.steps.last!) == nil)
        #expect(TextScale.smaller(than: TextScale.steps.first!) == nil)
    }

    @Test func zoomingIsReversible() {
        for step in TextScale.steps.dropLast() {
            let up = try! #require(TextScale.larger(than: step))
            #expect(TextScale.smaller(than: up) == step)
        }
    }

    @Test func titlesReadAsWholePercentages() {
        #expect(TextScale.title(for: 1.0) == "100%")
        #expect(TextScale.title(for: 1.15) == "115%")
        #expect(TextScale.title(for: 2.0) == "200%")
    }

    // MARK: - Layout

    @Test func panesWidenWithTheTextScale() {
        for step in TextScale.steps where step != TextScale.standard {
            let grows = step > TextScale.standard
            #expect((PaneLayout.analysisMinWidth(scale: step)
                > PaneLayout.analysisMinWidth()) == grows)
            #expect((PaneLayout.outlineDefaultWidth(scale: step)
                > PaneLayout.outlineDefaultWidth()) == grows)
            #expect((PaneLayout.sunburstLegendMaxWidth(scale: step)
                > PaneLayout.sunburstLegendMaxWidth()) == grows)
        }
    }

    /// The load-bearing invariant: at every step the window's own minimum
    /// still fits both side panes at their minimum *and* a minimum map. The
    /// pane minimums scale with the text; the map's floor does not, which is
    /// exactly what buys the room.
    @Test func windowMinimumHoldsBothPanesAndAMap() {
        for step in TextScale.steps {
            let needed = PaneLayout.outlineMinWidth(scale: step)
                + PaneLayout.analysisMinWidth(scale: step)
                + PaneLayout.mapMinWidth
                + 2 * PaneLayout.splitterThickness
            #expect(needed <= PaneLayout.windowMinWidth(scale: step))

            let neededHeight = PaneLayout.bottomOutlineMinHeight(scale: step)
                + PaneLayout.mapColumnMinHeight
                + PaneLayout.splitterThickness
            #expect(neededHeight <= PaneLayout.windowMinHeight(scale: step))

            // The sunburst splits the same window between legend and chart.
            let neededLegend = PaneLayout.sunburstLegendMinWidth(scale: step)
                + PaneLayout.sunburstChartMinWidth
                + PaneLayout.splitterThickness
            #expect(neededLegend <= PaneLayout.windowMinWidth(scale: step))
        }
    }

    /// A pane width persisted at 100% is narrower than the larger size's
    /// minimum, so it clamps up on read rather than staying cramped. The
    /// stored value is never written back (PaneLayout's clamp-on-read
    /// policy), so returning to 100% restores it.
    @Test func storedWidthsClampUpAtLargerText() {
        let stored = PaneLayout.outlineDefaultWidth()
        let metrics = WorkspacePaneMetrics(
            available: CGSize(width: 2_000, height: 1_200),
            showsLeadingOutline: true,
            showsAnalysis: true,
            storedOutlineWidth: stored,
            storedAnalysisWidth: PaneLayout.analysisDefaultWidth(),
            storedBottomOutlineHeight: PaneLayout.bottomOutlineDefaultHeight(),
            textScale: 2.0
        )
        #expect(metrics.outlineWidth > stored)
        #expect(metrics.outlineWidth == PaneLayout.outlineMinWidth(scale: 2.0))
        #expect(metrics.analysisWidth == PaneLayout.analysisMinWidth(scale: 2.0))
    }

    @Test func mapKeepsItsMinimumWidthAtEveryTextScale() {
        for step in TextScale.steps {
            let width = PaneLayout.windowMinWidth(scale: step)
            let metrics = WorkspacePaneMetrics(
                available: CGSize(width: width, height: PaneLayout.windowMinHeight(scale: step)),
                showsLeadingOutline: true,
                showsAnalysis: true,
                storedOutlineWidth: PaneLayout.outlineMaxWidth(scale: step),
                storedAnalysisWidth: PaneLayout.analysisMaxWidth(scale: step),
                storedBottomOutlineHeight: PaneLayout.bottomOutlineMaxHeight(scale: step),
                textScale: step
            )
            let map = width - metrics.outlineWidth - metrics.analysisWidth
                - 2 * PaneLayout.splitterThickness
            #expect(map >= PaneLayout.mapMinWidth)
        }
    }

    @Test func sunburstLegendConcedesToTheChartAtLargeText() {
        // A window that fits the 100% legend but not the 200% one hides the
        // legend rather than squeezing the chart below its minimum.
        let width = PaneLayout.sunburstLegendMinWidth()
            + PaneLayout.sunburstChartMinWidth + PaneLayout.splitterThickness
        #expect(SunburstLegendMetrics(
            availableWidth: width, storedWidth: 340, textScale: 1.0
        ).width != nil)
        #expect(SunburstLegendMetrics(
            availableWidth: width, storedWidth: 340, textScale: 2.0
        ).width == nil)
    }

    // MARK: - Control sizes

    /// A control's chrome comes from its control size, not its label font, so
    /// `neoControlSize` steps the size up. The property that keeps it safe to
    /// apply anywhere: at 100% it must hand back exactly the base it was
    /// given, or every deliberately `.small` control in the app silently
    /// grows.
    @Test func controlSizeIsUnchangedAtTheStandardScale() {
        for base in TextScale.controlSizes {
            #expect(TextScale.controlSize(base: base, scale: 1.0) == base)
        }
    }

    @Test func controlSizeStepsUpWithTheTextAndClampsAtTheTop() {
        #expect(TextScale.controlSize(base: .small, scale: 1.3) == .regular)
        #expect(TextScale.controlSize(base: .small, scale: 2.0) == .large)
        #expect(TextScale.controlSize(base: .regular, scale: 2.0) == .extraLarge)
        // Already at the top of the ladder: stays there rather than trapping.
        #expect(TextScale.controlSize(base: .extraLarge, scale: 2.0) == .extraLarge)
    }

    @Test func controlSizeNeverShrinks() {
        for base in TextScale.controlSizes {
            let start = TextScale.controlSizes.firstIndex(of: base)!
            for step in TextScale.steps {
                let grown = TextScale.controlSize(base: base, scale: CGFloat(step))
                #expect(TextScale.controlSizes.firstIndex(of: grown)! >= start)
            }
        }
    }

    // MARK: - Treemap labels

    /// The label gates are pre-filters sized for the label that will be drawn
    /// in them: bigger text demands a bigger cell, so a cell that carried a
    /// name at 100% may not at 200%. Area is two-dimensional, hence scale².
    @Test func treemapLabelGatesFollowTheLabelSize() {
        #expect(TreemapScene.labelMinCellWidth(scale: 2) == 2 * TreemapScene.labelMinCellWidth())
        #expect(TreemapScene.labelMinCellArea(scale: 2) == 4 * TreemapScene.labelMinCellArea())
        #expect(TreemapScene.flatFolderLabelMinCellHeight(scale: 2)
            == 2 * TreemapScene.flatFolderLabelMinCellHeight())
    }

    /// The flat header strip grows with its label, and the content region
    /// below it keeps the same floor — so nesting thins out gently instead of
    /// collapsing when the text doubles.
    @Test func flatContainerHeaderGrowsWithoutStarvingItsContents() {
        let big = CGRect(x: 0, y: 0, width: 400, height: 300)
        let plain = try! #require(TreemapScene.flatContentBounds(of: big))
        let scaled = try! #require(TreemapScene.flatContentBounds(of: big, scale: 2))
        #expect(scaled.minY > plain.minY)
        #expect(scaled.height < plain.height)

        // A container sized to nest at 100% but not at 200% renders as a
        // plain cell rather than a header with nothing under it.
        let tight = CGRect(
            x: 0, y: 0,
            width: TreemapScene.flatMinContainerWidth(),
            height: TreemapScene.flatMinContainerHeight()
        )
        #expect(TreemapScene.flatContentBounds(of: tight) != nil)
        #expect(TreemapScene.flatContentBounds(of: tight, scale: 2) == nil)
    }

    // MARK: - Outline rows

    /// The AppKit outline table has no environment to read: the view model
    /// pushes the scale into OutlineRowMetrics, which everything sized around
    /// a row's text derives from. The measurement cache holds widths for one
    /// scale, so it has to clear when the scale moves.
    @MainActor
    @Test func outlineRowMetricsFollowTheScale() {
        defer { OutlineRowMetrics.scale = 1 }

        OutlineRowMetrics.scale = 1
        let plainRow = OutlineRowMetrics.rowHeight
        let plainIndent = OutlineRowMetrics.indentPerDepth

        OutlineRowMetrics.scale = 2
        #expect(OutlineRowMetrics.fontSize == 2 * OutlineRowMetrics.baseFontSize)
        #expect(OutlineRowMetrics.rowHeight > plainRow)
        #expect(OutlineRowMetrics.indentPerDepth > plainIndent)
        // Row height is text plus a fixed margin, not a straight multiple:
        // larger text stays as dense as it can.
        #expect(OutlineRowMetrics.rowHeight < 2 * plainRow)
    }
}
