//
//  TreemapBreadcrumbBar.swift
//  Neodisk
//
//  Finder-style path bar above the treemap. Shows the ancestry of the current
//  selection (scan root → selected node). Clicking a crumb re-roots the treemap
//  to that folder — out to an ancestor above the current root, or in to a folder
//  below it — falling back to selecting the node when it isn't a drill target.
//  With nothing selected it shows just the scan root, so the bar is a persistent
//  orientation strip rather than one that appears and disappears.
//

import SwiftUI
import NeodiskKit

struct TreemapBreadcrumbBar: View {
    let model: NeodiskViewModel
    /// The sunburst's simplified layout leans on the bar for navigation, so
    /// it renders larger there; the treemap keeps the compact strip.
    var isProminent = false

    /// Root → selected node, falling back to the drill root with nothing
    /// selected: deselecting (e.g. clicking empty space in the sunburst)
    /// must not collapse the bar to the scan root while the map stays
    /// drilled into a subfolder. `path(to:)` returns `[root]` when both
    /// are nil, so the bar always has at least the scan root to show.
    private var crumbs: [FileNodeRecord] {
        guard let store = model.store else { return [] }
        return store.path(to: model.selectedNodeID ?? model.effectiveRootID)
    }

    var body: some View {
        if crumbs.isEmpty {
            // No scan loaded: take up no space (welcome/empty state).
            Color.clear.frame(height: 0)
        } else {
            bar
        }
    }

    private var bar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(isProminent ? .caption : .caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Crumb(
                            node: node,
                            isProminent: isProminent,
                            isLast: index == crumbs.count - 1,
                            // Underline the crumb the treemap is rooted at, so
                            // the drill depth is legible (only when drilled in).
                            isDrillRoot: model.zoomRootID != nil && node.id == model.effectiveRootID
                        ) {
                            // A crumb above the current map root drills back out
                            // to it; a folder below the root drills in to it
                            // (⌘↓ still works too). Otherwise: the root crumb
                            // clears the selection, any other crumb selects it.
                            if !model.reRoot(to: node.id) && !model.drillIn(to: node.id) {
                                model.select(index == 0 ? nil : node.id)
                            }
                        }
                        .id(node.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
            .onChange(of: model.selectedNodeID) {
                // Keep the deepest crumb in view as the selection moves.
                guard let last = crumbs.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            }
        }
        .frame(height: isProminent ? 34 : 26)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A single path segment. Ancestors are secondary and clickable; the trailing
/// segment (the selection itself) is emphasized.
private struct Crumb: View {
    let node: FileNodeRecord
    let isProminent: Bool
    let isLast: Bool
    let isDrillRoot: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(node.name.isEmpty ? "/" : node.name)
                .font(isProminent ? .body : .caption)
                .fontWeight(isLast ? .semibold : .regular)
                .underline(isDrillRoot)
                .lineLimit(1)
                .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, isProminent ? 7 : 5)
                .padding(.vertical, isProminent ? 4 : 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(NeodiskFormatters.size(node.allocatedSize))
    }
}
