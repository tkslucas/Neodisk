//
//  OutlineRows.swift
//  Neodisk
//
//  The SwiftUI content hosted inside the AppKit outline table's rows: the
//  scrolling name section, the viewport-pinned trailing cluster, and the
//  flat entire-scan search results list shown in the name section's place.
//

import SwiftUI
import NeodiskKit

// MARK: - Hosted row content

/// Indent, chevron, icon, and the full name — the part of a row that pans.
/// The name never truncates; when it outgrows the pane it slides under the
/// pinned trailing cluster and the tree becomes horizontally scrollable.
struct OutlineNameSection: View {
    let model: NeodiskViewModel
    let row: NeodiskViewModel.OutlineRow
    let state: OutlineRowSelectionState
    /// The bottom table's name column truncates in place (middle ellipsis)
    /// instead of panning; the left pane keeps the full-width pan behavior.
    var truncatesName = false

    var body: some View {
        HStack(spacing: 4) {
            Color.clear
                .frame(width: CGFloat(row.depth) * OutlineRowMetrics.indentPerDepth, height: 1)

            Group {
                if row.isExpandable {
                    Button {
                        model.toggleExpansion(row.node.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
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
            .frame(width: 14)

            Image(systemName: row.node.systemImageName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 16)

            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !truncatesName, vertical: false)
                .foregroundStyle(state.showsAccentSelection
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(.primary))

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, OutlineRowMetrics.contentInset)
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

    var body: some View {
        HStack(spacing: 4) {
            if model.coordinator.expandingNodeID == row.node.id {
                // A subtree rescan/expansion is scanning this folder.
                ProgressView()
                    .controlSize(.mini)
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
        .font(.system(size: 12))
        .padding(.trailing, trailingPadding)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Search results

/// Flat, score-ranked results of the entire-scan search. Selecting a row is
/// a normal outline selection: treemap highlight via the existing sync, and
/// ancestors expand so clearing the search shows the node in context.
struct OutlineSearchResultsList: View {
    let model: NeodiskViewModel
    let results: SearchModel.Results

    var body: some View {
        let selection = Binding<String?>(
            get: { model.selectedNodeID },
            set: { if let id = $0 { model.select(id) } }
        )

        if results.ids.isEmpty {
            Spacer()
            Text("No matches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List(results.ids, id: \.self, selection: selection) { nodeID in
                if let node = model.store?.node(id: nodeID) {
                    FileResultRow(
                        node: node,
                        palette: model.vizPalette,
                        includeCloudOnly: model.showsCloudOnlyFiles
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .fileNodeActions(model: model)
            .environment(\.defaultMinListRowHeight, 20)
            .quickLookOnSpace(model: model)

            if results.ids.count < results.totalMatches {
                Divider()
                Text("Top \(results.ids.count.formatted()) of \(results.totalMatches.formatted()) matches — refine to narrow")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }
}
