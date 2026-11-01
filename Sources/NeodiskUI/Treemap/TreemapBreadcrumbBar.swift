// Clicking a crumb re-roots out or in, else selects the node. With nothing selected it shows the scan root,
// so the bar is a persistent orientation strip.

import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct TreemapBreadcrumbBar: View {
    @Environment(\.neoTextScale) private var textScale

    let model: NeodiskViewModel

    /// Falls back to the drill root: deselecting must not collapse the bar while the map stays drilled in.
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
        GeometryReader { geometry in
            let crumbs = crumbs
            let shown = PathBarFit.shownIndices(
                widths: crumbs.indices.map { crumbWidth(crumbs[$0], isLast: $0 == crumbs.count - 1) },
                separator: separatorWidth,
                ellipsis: ellipsisWidth,
                available: geometry.size.width - 16
            )
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { position, index in
                    if position > 0 {
                        Image(systemName: "chevron.right")
                            .neoFont(8, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 1)
                    }
                    if let index {
                        crumb(crumbs[index], at: index, of: crumbs.count)
                    } else {
                        collapsedCrumbs(crumbs, hidden: PathBarFit.hiddenIndices(shown: shown, count: crumbs.count))
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: (28 * textScale).rounded())
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // The window's customize options, as on the map's empty space and the toolbar picker.
        .contextMenu { WorkspaceLayoutMenuItems(model: model) }
    }
}

extension TreemapBreadcrumbBar {
    private func crumb(_ node: FileNodeRecord, at index: Int, of count: Int) -> some View {
        Crumb(
            node: node,
            palette: model.vizPalette,
            isLast: index == count - 1,
            // Underline the crumb the treemap is rooted at, so the drill depth is legible (only when drilled in).
            isDrillRoot: model.zoomRootID != nil && node.id == model.effectiveRootID
        ) {
            navigate(to: node, isRoot: index == 0)
        }
        // Only the selection may shrink (middle-truncated); every other crumb keeps its whole name.
        .layoutPriority(index == count - 1 ? 0 : 1)
        .fixedSize(horizontal: index != count - 1, vertical: false)
    }

    /// Re-roots out or in; otherwise the root crumb clears the selection and any other crumb selects it.
    private func navigate(to node: FileNodeRecord, isRoot: Bool) {
        if !model.reRoot(to: node.id) && !model.drillIn(to: node.id) {
            model.select(isRoot ? nil : node.id)
        }
    }

    /// The folders that didn't fit, as a path control collapses them: an ellipsis whose menu lists them.
    private func collapsedCrumbs(_ crumbs: [FileNodeRecord], hidden: [Int]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { index in
                Button(crumbs[index].name.isEmpty ? "/" : crumbs[index].name) {
                    navigate(to: crumbs[index], isRoot: index == 0)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .neoFont(11)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 4)
        .layoutPriority(1)
    }

    /// Estimated from the font the crumb draws with: icon, spacing and padding included.
    private func crumbWidth(_ node: FileNodeRecord, isLast: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11 * textScale, weight: isLast ? .medium : .regular)
        let name = (node.name.isEmpty ? "/" : node.name) as NSString
        let text = ceil(name.size(withAttributes: [.font: font]).width)
        return text + (16 * textScale).rounded() + 3 + 7
    }

    private var separatorWidth: CGFloat { ceil(6 * textScale) + 2 }
    private var ellipsisWidth: CGFloat { ceil(14 * textScale) + 8 }
}

/// Which crumbs a path bar shows in a width: all when they fit; else the first and the last, with as many of the
/// last one's ancestors as fit between, the rest collapsed into one ellipsis (nil); in a very narrow bar only the
/// ellipsis and the last, which may then truncate.
enum PathBarFit {
    static func shownIndices(
        widths: [CGFloat], separator: CGFloat, ellipsis: CGFloat, available: CGFloat
    ) -> [Int?] {
        let count = widths.count
        guard count > 2 else { return Array(0..<count) }
        func total(_ indices: [Int?]) -> CGFloat {
            indices.reduce(CGFloat(0)) { $0 + ($1.map { widths[$0] } ?? ellipsis) } + CGFloat(indices.count - 1) * separator
        }
        let all = Array(0..<count).map { Optional($0) }
        if total(all) <= available { return all }
        var tail = [count - 1]
        for index in stride(from: count - 2, through: 2, by: -1) {
            let candidate: [Int?] = [0, nil] + ([index] + tail).map { Optional($0) }
            guard total(candidate) <= available else { break }
            tail.insert(index, at: 0)
        }
        let withRoot: [Int?] = [0, nil] + tail.map { Optional($0) }
        if total(withRoot) <= available || tail.count > 1 { return withRoot }
        return [nil, count - 1]
    }

    static func hiddenIndices(shown: [Int?], count: Int) -> [Int] {
        let visible = Set(shown.compactMap { $0 })
        return (0..<count).filter { !visible.contains($0) }
    }
}

/// A single path segment, icon then name like a path control. Ancestors are secondary and clickable; the
/// trailing segment (the selection itself) is emphasized.
private struct Crumb: View {
    let node: FileNodeRecord
    let palette: VizPalette
    let isLast: Bool
    let isDrillRoot: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                FileCategoryIcon(node: node, palette: palette)
                Text(node.name.isEmpty ? "/" : node.name)
                    .neoFont(11, weight: isLast ? .medium : .regular)
                    .underline(isDrillRoot)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(.leading, 2)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .neoHelp(NeodiskFormatters.size(node.allocatedSize))
    }
}
