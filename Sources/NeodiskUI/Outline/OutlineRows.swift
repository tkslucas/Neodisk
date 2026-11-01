// SwiftUI content hosted in the AppKit outline table's rows, plus the flat search results list.

import SwiftUI
import NeodiskKit

// MARK: - Hosted row content

/// The name never truncates: it slides under the pinned trailing cluster and the tree scrolls horizontally.
struct OutlineNameSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState
    /// The bottom table's name column truncates in place (middle ellipsis)
    /// instead of panning; the left pane keeps the full-width pan behavior.
    var truncatesName = false
    /// Where the chevron's slot starts: the left pane's edge inset, or the bottom table's name column edge.
    var leadingInset = OutlineRowMetrics.nameLeadingInset
    /// Each level's indentation; the bottom table narrows it for deep trees.
    var indentPerDepth = OutlineRowMetrics.indentPerDepth
    /// Never read, but makes a text-size change a change to the view's value; otherwise a reused cell keeps
    /// the old font and widths (issue #10).
    var scale = OutlineRowMetrics.scale

    var body: some View {
        let cleanupMark = model.cleanup.mark(for: row.node.id)
        // Slot widths and glyph sizes come from OutlineRowMetrics, which the
        // AppKit table also measures against — see the mirror note there.
        HStack(spacing: OutlineRowMetrics.rowSpacing) {
            Group {
                if row.isExpandable {
                    Button {
                        model.toggleExpansion(row.node.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(
                                size: OutlineRowMetrics.chevronFontSize, weight: .semibold
                            ))
                            .rotationEffect(
                                .degrees(model.expandedNodeIDs.contains(row.node.id) ? 90 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chevronStyle)
                } else {
                    Color.clear
                }
            }
            .frame(width: OutlineRowMetrics.chevronSlotWidth)

            Image(systemName: row.node.systemImageName)
                .font(.system(size: OutlineRowMetrics.iconFontSize))
                .foregroundStyle(iconColor)
                .frame(width: OutlineRowMetrics.iconSlotWidth)

            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !truncatesName, vertical: false)
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(.primary))

            if cleanupMark.isItem {
                CleanupRowGlyph(pointSize: OutlineRowMetrics.fontSize, onAccent: state.showsAccentSelection)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: OutlineRowMetrics.fontSize))
        .cleanupDimmed(cleanupMark.isMarked, onAccent: state.showsAccentSelection)
        .padding(.leading, leadingInset + CGFloat(row.depth) * indentPerDepth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var chevronStyle: AnyShapeStyle {
        state.showsAccentSelection
            ? AnyShapeStyle(.white.opacity(0.85))
            : AnyShapeStyle(.secondary)
    }

    private var iconColor: Color {
        if row.node.isDirectory {
            return .secondary
        }
        return model.kinds.catalog.color(for: row.node)
    }
}

/// Spinner, diff delta, and size — the trailing cluster pinned to the
/// pane's right edge at every horizontal scroll position.
struct OutlineTrailingSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState
    /// The left pane pins this cluster at its 16pt edge inset; the bottom
    /// table's size column brings its own, much tighter padding.
    var trailingPadding: CGFloat = OutlineRowMetrics.contentInset
    /// See OutlineNameSection.scale.
    var scale = OutlineRowMetrics.scale

    var body: some View {
        HStack(spacing: 4) {
            if model.coordinator.expandingNodeID == row.node.id {
                // A subtree rescan/expansion is scanning this folder.
                ProgressView()
                    .neoControlSize(base: .mini)
            }

            if let baseline = model.diff.baseline {
                DeltaLabel(delta: baseline.sizeDelta(for: row.node))
            }

            FileSizeLabel(node: row.node, includeCloudOnly: model.showsCloudOnlyFiles)
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white.opacity(0.85))
                    : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: OutlineRowMetrics.fontSize))
        .cleanupDimmed(model.cleanup.isInsideCollected(row.node.id), onAccent: state.showsAccentSelection)
        .padding(.trailing, trailingPadding)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Cleanup marks

/// The small trash after a collected item's name, in every list.
struct CleanupRowGlyph: View {
    /// The outline's AppKit-hosted rows pass their scaled point size; other rows scale through `.neoFont`.
    var pointSize: CGFloat? = nil
    var onAccent = false

    var body: some View {
        Group {
            if let pointSize {
                Image(systemName: "trash").font(.system(size: (pointSize * 0.85).rounded(), weight: .medium))
            } else {
                Image(systemName: "trash").neoFont(10, weight: .medium)
            }
        }
        .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .accessibilityLabel(Text("In Cleanup"))
    }
}

/// Dims a cell that has no Cleanup awareness of its own (the bottom table's detail columns).
struct CleanupDimming<Content: View>: View {
    let cleanup: CleanupModel
    let nodeID: String
    let state: OutlineRowSelectionState
    let content: Content

    var body: some View {
        content.cleanupDimmed(cleanup.isInsideCollected(nodeID), onAccent: state.showsAccentSelection)
    }
}

extension View {
    /// Rows in Cleanup (or inside a collected folder) recede; on the accent selection they stay legible.
    func cleanupDimmed(_ dimmed: Bool, onAccent: Bool = false) -> some View {
        opacity(dimmed ? (onAccent ? 0.7 : 0.45) : 1)
    }
}

// MARK: - Search results

/// Selecting a row is a normal outline selection, and ancestors expand so clearing search shows context.
struct OutlineSearchResultsList: View {
    let model: NeodiskViewModel
    let results: SearchModel.Results

    var body: some View {
        if results.ids.isEmpty {
            Spacer()
            Text("No matches")
                .neoFont(11)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            // The same AppKit list as the statistics tabs: rows drag out and onto Cleanup, and long result
            // lists never re-measure.
            StatsListTable(
                model: model,
                rows: results.ids.compactMap { model.store?.node(id: $0) },
                click: .selectsNode { model.select($0) },
                selection: model.selection,
                keepsLeaderInView: true
            ) { node in
                FileResultRow(
                    node: node,
                    palette: model.vizPalette,
                    includeCloudOnly: model.showsCloudOnlyFiles,
                    cleanup: model.cleanup
                )
            }

            if results.ids.count < results.totalMatches {
                Divider()
                Text("Top \(results.ids.count.formatted()) of \(results.totalMatches.formatted()) matches — refine to narrow")
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }
}
