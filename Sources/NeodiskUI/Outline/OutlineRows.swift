// SwiftUI content hosted in the AppKit outline table's rows, plus the flat search results list.

import SwiftUI
import NeodiskKit

// MARK: - Hosted row content

/// A long name truncates in the middle, as in Finder, with the full name as its tooltip.
struct OutlineNameSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState
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
                        // Option-click opens or closes everything below, as in Finder.
                        model.toggleExpansion(
                            row.node.id, recursively: NSApp.currentEvent?.modifierFlags.contains(.option) == true
                        )
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

            // The whole name when it fits; otherwise the middle gives way and the tooltip holds the rest.
            ViewThatFits(in: .horizontal) {
                Text(row.node.name)
                    .lineLimit(1)
                    .fixedSize()
                Text(row.node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .neoHelp(row.node.name)
            }
            .layoutPriority(1)
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

/// Spinner, diff delta, size and collection action — the trailing cluster pinned to the
/// pane's right edge at every horizontal scroll position.
struct OutlineTrailingSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState
    /// The left pane pins this cluster at its 16pt edge inset; the bottom
    /// table's size column brings its own, much tighter padding.
    var trailingPadding: CGFloat = OutlineRowMetrics.contentInset
    /// The bottom table gives the action a separate column after all of its data columns.
    var showsCleanupButton = true
    /// See OutlineNameSection.scale.
    var scale = OutlineRowMetrics.scale

    var body: some View {
        HStack(spacing: 4) {
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
            // The action stays at full strength: on a collected row it's the way back.
            .cleanupDimmed(model.cleanup.isInsideCollected(row.node.id), onAccent: state.showsAccentSelection)

            if showsCleanupButton {
                CleanupRowButton(
                    node: row.node, cleanup: model.cleanup,
                    pointSize: OutlineRowMetrics.fontSize, onAccent: state.showsAccentSelection
                )
            }
        }
        .font(.system(size: OutlineRowMetrics.fontSize))
        .padding(.trailing, trailingPadding)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Cleanup marks

/// A fixed trailing action column: adding to Cleanup never shifts the size or filename. A collected item's slot
/// shows Cleanup's own remove button under the pointer, so a second click right where the first one landed undoes it.
struct CleanupRowButton: View {
    let node: FileNodeRecord?
    let cleanup: CleanupModel
    /// AppKit outline rows pass their scaled size; the other lists inherit the workspace scale.
    var pointSize: CGFloat? = nil
    var onAccent = false

    @Environment(\.neoTextScale) private var textScale
    @State private var isHovered = false

    static func sideLength(pointSize: CGFloat) -> CGFloat { pointSize + 8 }

    var body: some View {
        let size = pointSize ?? 12 * textScale
        Group {
            if let node, cleanup.isEnabled, cleanup.mark(for: node.id) == .collected {
                Button {
                    cleanup.remove([node.id])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: size))
                        .frame(width: Self.sideLength(pointSize: size), height: Self.sideLength(pointSize: size))
                        .contentShape(Rectangle())
                        .opacity(isHovered ? 1 : 0)
                }
                .buttonStyle(.plain)
                .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .disabled(cleanup.isMoving)
                .accessibilityLabel(Text("Remove from Cleanup"))
                .accessibilityValue(Text(verbatim: node.name))
                .neoHelp("Remove from Cleanup")
            } else if let node, cleanup.isEnabled, !cleanup.mark(for: node.id).isItem {
                let mark = cleanup.mark(for: node.id)
                let reason = mark.hoverText ?? (cleanup.isMoving
                    ? CleanupModel.Mark.moving.hoverText : cleanup.refusalReason(for: node))
                Button {
                    cleanup.add([node])
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.75, weight: .medium))
                        .frame(width: Self.sideLength(pointSize: size), height: Self.sideLength(pointSize: size))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(onAccent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .disabled(reason != nil || mark.isMarked || cleanup.isMoving)
                .accessibilityLabel(Text("Add to Cleanup"))
                .accessibilityValue(Text(verbatim: node.name))
                .neoHelp(reason ?? NSLocalizedString("Add to Cleanup", comment: "Inline file collection button"))
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(width: Self.sideLength(pointSize: size), height: Self.sideLength(pointSize: size))
        .fixedSize()
        .onHover { isHovered = $0 }
    }
}

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

    private var footerText: String {
        String(
            format: NSLocalizedString("Top %@ of %@ matches — refine to narrow", comment: "Search results footer"),
            results.ids.count.formatted(), results.totalMatches.formatted()
        )
    }

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
                keepsLeaderInView: true,
                footer: results.ids.count < results.totalMatches ? footerText : nil
            ) { node in
                FileResultRow(
                    node: node,
                    palette: model.vizPalette,
                    includeCloudOnly: model.showsCloudOnlyFiles,
                    cleanup: model.cleanup
                )
            }
        }
    }
}
