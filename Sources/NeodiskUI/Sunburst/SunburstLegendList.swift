//
//  SunburstLegendList.swift
//  Neodisk
//
//  The legend beside the sunburst chart: a header for the
//  displayed folder and one row per child, colored exactly like the chart's
//  segments (rows derive from the rendered layout via SunburstLegend).
//  Hovering a row highlights its arc in the chart and feeds the status bar;
//  hovering the chart highlights the containing row here. Clicks, the
//  context menu, and pinch-to-drill mirror the chart's segment interactions.
//

import SwiftUI
import NeodiskKit

struct SunburstLegendList: View {
    static let width: CGFloat = 340

    let model: NeodiskViewModel
    @ObservedObject var chartModel: SunburstChartModel
    /// The folder the list describes: the chart-hover preview folder when
    /// one is set, otherwise the chart root.
    let displayedFolder: FileNodeRecord
    let chartRootID: String
    let style: SunburstColorStyle
    let onHoverRow: (SunburstLegendRow?) -> Void
    let onClickRow: (SunburstLegendRow) -> Void
    /// A pinch committed over the list: the hovered row (nil over the
    /// header or gaps) and the pinch direction, chart-parity semantics.
    let onPinchRow: (SunburstLegendRow?, SunburstPinchDirection) -> Void

    /// The row the pointer is over, tracked locally so a stale exit event
    /// from the previous row cannot clear a newer row's hover.
    @State private var hoveredRowID: String?
    /// The shared "one drill per pinch" latch, matching the chart overlay.
    @State private var pinchRecognizer = PinchDrillRecognizer()

    var body: some View {
        let rows = legendRows
        let highlightedRowID = highlightedRowID(in: rows)

        ZStack {
            VStack(spacing: 0) {
                if let store = model.store {
                    LegendRowView(
                        row: SunburstLegend.headerRow(
                            forFolder: displayedFolder,
                            chartRootID: chartRootID,
                            in: store,
                            segments: chartModel.renderedSegments,
                            style: style,
                            includeCloudOnly: model.showsCloudOnlyFiles,
                            sizeOverride: headerSizeOverride(store: store)
                        ),
                        isHeader: true,
                        isSelected: false,
                        isHighlighted: false,
                        reservesCloudGlyphSlot: model.showsCloudOnlyFiles
                    )
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    Divider()
                        .padding(.horizontal, 10)

                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { row in
                                interactiveRow(row, isHighlighted: row.id == highlightedRowID)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            // Swapping the identity when the displayed folder changes (hover
            // preview, drill) restarts the scroll at the top instead of
            // keeping a stale offset — and gives the transition an
            // insertion/removal to animate, so the legend cross-fades (the
            // pane wraps preview changes in withAnimation).
            .id(displayedFolder.id)
            .transition(.opacity)
        }
        .frame(width: Self.width)
        .simultaneousGesture(pinchDrillGesture(rows: rows))
    }

    // MARK: - Pinch to drill

    /// Pinch-to-drill on the list, matching the chart overlay's contract via
    /// the shared PinchDrillRecognizer: the first threshold crossing commits
    /// one drill and latches until the fingers lift. MagnifyGesture reports an
    /// absolute ratio, so 1 ± threshold is the same finger travel the chart's
    /// accumulated ±threshold covers.
    private func pinchDrillGesture(rows: [SunburstLegendRow]) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if let direction = pinchRecognizer.update(ratio: value.magnification) {
                    onPinchRow(rows.first { $0.id == hoveredRowID }, direction)
                }
            }
            .onEnded { _ in
                pinchRecognizer.end()
            }
    }

    // MARK: - Rows

    /// For a volume scan showing the whole tree, the header states the
    /// Finder/Disk Utility "used" figure — the same number as the window
    /// title — so the legend tiles: children + hidden space = header, plus
    /// free space = capacity. Drilled or hover-previewed folders keep their
    /// own weight.
    private func headerSizeOverride(store: FileTreeStore) -> Int64? {
        guard displayedFolder.id == chartRootID,
              chartRootID == store.rootID,
              model.coordinator.selectedTarget?.kind == .volume else { return nil }
        return model.freeSpace.finderUsedBytes
    }

    private var legendRows: [SunburstLegendRow] {
        guard let store = model.store else { return [] }
        return SunburstLegend.rows(
            forFolder: displayedFolder.id,
            chartRootID: chartRootID,
            in: store,
            segments: chartModel.renderedSegments,
            style: style,
            includeCloudOnly: model.showsCloudOnlyFiles
        )
    }

    @ViewBuilder
    private func interactiveRow(_ row: SunburstLegendRow, isHighlighted: Bool) -> some View {
        let rowView = LegendRowView(
            row: row,
            isHeader: false,
            isSelected: isSelected(row),
            isHighlighted: isHighlighted,
            reservesCloudGlyphSlot: model.showsCloudOnlyFiles
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveredRowID = row.id
                onHoverRow(row)
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
                onHoverRow(nil)
            }
        }
        .onTapGesture {
            onClickRow(row)
        }
        .contextMenu {
            contextMenuItems(for: row)
        }

        if let helpText = helpText(for: row) {
            rowView.help(helpText)
        } else {
            rowView
        }
    }

    /// Hidden space is the one legend entry whose meaning isn't obvious
    /// from its label; a tooltip explains what pooled into it.
    private func helpText(for row: SunburstLegendRow) -> String? {
        guard row.target == .hiddenSpace else { return nil }
        return NSLocalizedString(
            "Purgeable space, local snapshots, and files the scan could not see.",
            comment: "Hidden-space explanation tooltip"
        )
    }

    private func isSelected(_ row: SunburstLegendRow) -> Bool {
        guard case .node(let nodeID, _) = row.target else { return false }
        return nodeID == model.selectedNodeID
    }

    /// The row the chart hover maps to: the free/hidden-space rows, the
    /// aggregate row, the hovered node's own row, or its top-level
    /// ancestor's row. List-row hover feeds the same model state, so a
    /// hovered row highlights itself through this too.
    private func highlightedRowID(in rows: [SunburstLegendRow]) -> String? {
        if model.hoveredCellIsFreeSpace {
            return rows.first { $0.target == .freeSpace }?.id
        }
        if model.hoveredCellIsHiddenSpace {
            return rows.first { $0.target == .hiddenSpace }?.id
        }
        guard let hoveredID = model.hoveredNodeID, let store = model.store else { return nil }
        if model.hoveredAggregate != nil, hoveredID == displayedFolder.id {
            return rows.first { $0.target == .aggregate }?.id
        }
        guard hoveredID != displayedFolder.id,
              let rowNodeID = SunburstLegend.rowNodeID(
                forHovered: hoveredID,
                displayedFolderID: displayedFolder.id,
                in: store
              ) else { return nil }
        if rows.contains(where: { $0.id == rowNodeID }) {
            return rowNodeID
        }
        // The containing child was pooled into the aggregate segment.
        return rows.first { $0.target == .aggregate }?.id
    }

    /// Same actions as the chart segments' context menu, gated the same way.
    @ViewBuilder
    private func contextMenuItems(for row: SunburstLegendRow) -> some View {
        if case .node(let nodeID, _) = row.target,
           let node = model.store?.node(id: nodeID),
           model.supportsFileActions(node) {
            Button("Reveal in Finder") { model.reveal(node) }
            Button("Open") { model.open(node) }
            Button("Copy Path") { model.copyPath(node) }
            if let expansion = model.contentsExpansion(for: node) {
                Divider()
                Button(LocalizedStringKey(expansion.menuTitleKey)) { model.expandNodeContents(node) }
                    .disabled(!model.canRefreshSubtree)
            }
        }
    }
}

// MARK: - Row view

private struct LegendRowView: View {
    let row: SunburstLegendRow
    let isHeader: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    /// Reserve the trailing glyph slot on every row (the cloud-only toggle
    /// is on), so sizes right-align whether or not a row shows the glyph.
    var reservesCloudGlyphSlot: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(row.dotColor)
                .frame(width: dotSize, height: dotSize)
            Text(verbatim: row.label)
                .font(labelFont)
                .foregroundStyle(row.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: NeodiskFormatters.size(row.size))
                .font(sizeFont)
                .monospacedDigit()
                .foregroundStyle(isHeader ? .primary : .secondary)
            if reservesCloudGlyphSlot {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isHeader ? .primary : .secondary)
                    .opacity(row.showsCloudGlyph ? 1 : 0)
                    .frame(width: FileSizeLabel.glyphSlotWidth)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isHeader ? 6 : 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
                .padding(.horizontal, 4)
        )
    }

    private var dotSize: CGFloat {
        isHeader ? 14 : 12
    }

    private var labelFont: Font {
        isHeader ? .system(size: 16, weight: .semibold) : .system(size: 14)
    }

    private var sizeFont: Font {
        isHeader ? .system(size: 14, weight: .semibold) : .system(size: 13)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.22)
        }
        if isHighlighted {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}
