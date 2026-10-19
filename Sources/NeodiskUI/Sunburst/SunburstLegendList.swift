// Legend beside the sunburst; rows derive from the rendered layout via SunburstLegend, so colors match.
// Hover, clicks, context menu and pinch-to-drill mirror the chart's segments.

import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct SunburstLegendList: View {
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

    @ViewBuilder
    var body: some View {
        if let presentation = legendPresentation {
            legendContent(presentation)
                .simultaneousGesture(pinchDrillGesture(rows: presentation.rows))
                .onChange(of: style) { _, _ in
                    guard let hoveredRowID,
                          let row = presentation.rows.first(where: { $0.id == hoveredRowID })
                    else { return }
                    onHoverRow(row)
                }
        } else {
            Color.clear
        }
    }

    private func legendContent(_ presentation: SunburstLegendPresentation) -> some View {
        let rows = presentation.rows
        let highlightedRowID = highlightedRowID(in: presentation)

        return ZStack {
            VStack(spacing: 0) {
                LegendRowView(
                    row: presentation.header,
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
            // A new identity per displayed folder resets the scroll to the top and gives the transition an
            // insertion/removal to cross-fade.
            .id(displayedFolder.id)
            .transition(.opacity)
        }
        // Width is owned by SunburstPane: user-resizable, clamped against
        // the pane so the chart keeps a usable diameter (SunburstLegendMetrics).
    }

    // MARK: - Pinch to drill

    /// The first threshold crossing commits one drill and latches until the fingers lift. MagnifyGesture is
    /// an absolute ratio, so 1 ± threshold matches the chart's accumulated travel.
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

    /// For a whole volume, the header shows the system "used" figure (as the window title) so children plus
    /// hidden space tile it. Drilled or previewed folders keep their own weight.
    private func headerSizeOverride(store: FileTreeStore) -> Int64? {
        guard displayedFolder.id == chartRootID,
              chartRootID == store.rootID,
              model.coordinator.selectedTarget?.kind == .volume else { return nil }
        return model.freeSpace.finderUsedBytes
    }

    private var legendPresentation: SunburstLegendPresentation? {
        guard let store = model.store else { return nil }
        return chartModel.legendPresentation(
            displayedFolder: displayedFolder,
            chartRootID: chartRootID,
            in: store,
            style: style,
            includeCloudOnly: model.showsCloudOnlyFiles,
            expandedAggregateIDs: model.expandedAggregateIDs,
            headerSizeOverride: headerSizeOverride(store: store)
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

    /// List-row hover feeds the same model state, so a hovered row highlights itself through this too.
    private func highlightedRowID(in presentation: SunburstLegendPresentation) -> String? {
        switch model.visualizationHover {
        case .freeSpace:
            return presentation.freeSpaceRowID
        case .hiddenSpace:
            return presentation.hiddenSpaceRowID
        case .aggregate(let folderID, _, _, _) where folderID == displayedFolder.id:
            return presentation.aggregateRowID
        default:
            break
        }
        guard let hoveredID = model.hoveredNodeID, let store = model.store else { return nil }
        guard hoveredID != displayedFolder.id,
              let rowNodeID = SunburstLegend.rowNodeID(
                forHovered: hoveredID,
                displayedFolderID: displayedFolder.id,
                in: store
              ) else { return nil }
        if presentation.rowIDs.contains(rowNodeID) {
            return rowNodeID
        }
        // The containing child was pooled into the aggregate segment.
        return presentation.aggregateRowID
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
    @Environment(\.neoTextScale) private var textScale

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
                .neoFont(labelFont)
                .foregroundStyle(row.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: NeodiskFormatters.size(row.size))
                .neoFont(sizeFont)
                .monospacedDigit()
                .foregroundStyle(isHeader ? .primary : .secondary)
            if reservesCloudGlyphSlot {
                Image(systemName: "cloud.fill")
                    .neoFont(9, weight: .medium)
                    .foregroundStyle(isHeader ? .primary : .secondary)
                    .opacity(row.showsCloudGlyph ? 1 : 0)
                    .frame(width: FileSizeLabel.glyphSlotWidth(scale: textScale))
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
        (isHeader ? 14 : 12) * textScale
    }

    private var labelFont: NeoFont {
        isHeader ? NeoFont(16, weight: .semibold) : NeoFont(14)
    }

    private var sizeFont: NeoFont {
        isHeader ? NeoFont(14, weight: .semibold) : NeoFont(13)
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
