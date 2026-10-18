// The text scale's step ladder and snapping, and its layout effects on panes, window minimum and labels.

import Foundation
import SwiftUI
import Testing
@testable import NeodiskUI
@testable import NeodiskAppModel

// Serialized: two tests drive the process-wide OutlineRowMetrics.scale.
@Suite(.serialized) struct TextScaleTests {
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

    /// The pane minimums scale with the text but the map floor doesn't, which is what buys the room.
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

    /// Clamps up on read and is never written back, so returning to 100% restores it.
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
            // A pane that can't dock floats over the map instead.
            let docked = metrics.analysisFloats
                ? 0 : metrics.analysisWidth + PaneLayout.splitterThickness
            let map = width - metrics.outlineWidth - PaneLayout.splitterThickness - docked
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

    /// At 100% it must return exactly the base, or every deliberately `.small` control silently grows.
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

    /// Bigger text demands a bigger cell; area is two-dimensional, hence scale².
    @Test func treemapLabelGatesFollowTheLabelSize() {
        #expect(TreemapScene.labelMinCellWidth(scale: 2) == 2 * TreemapScene.labelMinCellWidth())
        #expect(TreemapScene.labelMinCellArea(scale: 2) == 4 * TreemapScene.labelMinCellArea())
        #expect(TreemapScene.flatFolderLabelMinCellHeight(scale: 2)
            == 2 * TreemapScene.flatFolderLabelMinCellHeight())
    }

    /// The content floor stays put, so nesting thins out gently instead of collapsing when text doubles.
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

    /// The AppKit table has no environment, so the model pushes the scale into OutlineRowMetrics.
    /// Its measurement cache holds one scale's widths, so it must clear when the scale moves.
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

    /// Reused cells get the same row after a text-size change; without the scale in the value SwiftUI skips
    /// the body and keeps the old font (issue #10). Only the live table shows it, so this pins the invariant.
    @MainActor
    @Test func outlineRowViewsCarryTheScaleTheyWereBuiltFor() {
        defer { OutlineRowMetrics.scale = 1 }

        let model = NeodiskViewModel()
        let row = NeodiskViewModel.OutlineRow(
            node: makeTestFileNode(id: "/scan/notes.txt", name: "notes.txt", size: 4096),
            depth: 1,
            isExpandable: false,
            fractionOfParent: 0.5
        )
        let state = OutlineRowSelectionState()

        OutlineRowMetrics.scale = 1
        let plainName = OutlineNameSection(model: model, row: row, state: state)
        let plainCluster = OutlineTrailingSection(model: model, row: row, state: state)

        OutlineRowMetrics.scale = 2
        let zoomedName = OutlineNameSection(model: model, row: row, state: state)
        let zoomedCluster = OutlineTrailingSection(model: model, row: row, state: state)

        #expect(plainName.scale == 1)
        #expect(zoomedName.scale == 2)
        #expect(plainCluster.scale == 1)
        #expect(zoomedCluster.scale == 2)
    }
}
