// The active tab decides what treemap color means (see NeodiskViewModel.vizColorMode).

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel

enum AnalysisTab: String, CaseIterable, Identifiable, Sendable {
    case largest
    case kinds
    case age
    case duplicates
    case changes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largest: return "Largest"
        case .kinds: return "Kinds"
        case .age: return "Age"
        case .duplicates: return "Duplicates"
        case .changes: return "Changes"
        }
    }
}

struct AnalysisPane: View {
    let model: NeodiskViewModel

    var body: some View {
        VStack(spacing: 0) {
            AnalysisTabBar(model: model)

            Divider()

            switch model.analysisTab {
            case .largest:
                LargestPane(model: model)
            case .kinds:
                KindStatsPane(model: model)
            case .age:
                AgeStatsPane(model: model)
            case .duplicates:
                DuplicatesPane(model: model)
            case .changes:
                ChangesPane(model: model)
            }

            // Keyed off the scanned root, matching the panes' totals (aggregateStats is the whole-scan root).
            if model.snapshotHasCloudItems, let store = model.store {
                Divider()
                CloudSummaryStrip(
                    onThisMac: store.root.allocatedSize,
                    cloudOnly: store.root.cloudOnlyLogicalSize
                )
            }
        }
    }
}

/// Text tabs, not a segmented picker: bezel padding truncates localized titles. Tabs that don't fit go in a »
/// menu instead of truncating; right-click shows or hides them. Dragging a tab moves the tab itself (no drag
/// image): its neighbors slide aside as it crosses their middles, and it settles into its slot on release.
private struct AnalysisTabBar: View {
    let model: NeodiskViewModel

    @Namespace private var underlineNamespace
    @Environment(\.neoTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var drag: TabDrag?

    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 10

    private struct TabDrag: Equatable {
        let tab: AnalysisTab
        /// Where in the tab the pointer took hold of it.
        let grab: CGFloat
        /// The tab's leading edge, following the pointer.
        var left: CGFloat
    }

    var body: some View {
        let (shown, overflow) = fitting()
        let slots = slots(for: shown)
        HStack(spacing: Self.spacing) {
            ForEach(shown) { tab in
                AnalysisTabButton(
                    tab: tab,
                    isActive: model.analysisTab == tab,
                    namespace: underlineNamespace
                ) {
                    select(tab)
                }
                .offset(x: offset(of: tab, slots: slots))
                .zIndex(drag?.tab == tab ? 1 : 0)
                .transaction { if drag?.tab == tab { $0.animation = nil } }
                .simultaneousGesture(reorderGesture(for: tab, shown: shown, slots: slots))
            }
            Spacer(minLength: 0)
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { tab in
                        Button(LocalizedStringKey(tab.title)) { select(tab) }
                    }
                } label: {
                    Image(systemName: "chevron.right.2")
                        .neoFont(10, weight: .semibold)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help(Text("More tabs"))
            }
        }
        .padding(.horizontal, Self.padding)
        // minWidth 0: the bar measures the pane, not its own tabs.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .coordinateSpace(name: Self.space)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .contextMenu { visibilityMenu }
    }

    private static let space = "analysisTabBar"

    private var settle: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }

    @ViewBuilder
    private var visibilityMenu: some View {
        let layout = model.analysisTabs
        ForEach(layout.order) { tab in
            Toggle(LocalizedStringKey(tab.title), isOn: Binding(
                get: { !layout.isHidden(tab) },
                set: { isShown in
                    var updated = layout
                    updated.setHidden(tab, !isShown)
                    withAnimation(settle) { model.setAnalysisTabs(updated) }
                }
            ))
            .disabled(!layout.isHidden(tab) && !layout.canHide(tab))
        }
        Divider()
        Button("Reset Tabs") {
            withAnimation(settle) { model.setAnalysisTabs(ItemLayout()) }
        }
        .disabled(layout.isStandard)
    }

    private func select(_ tab: AnalysisTab) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.analysisTab = tab
        }
    }

    // MARK: Dragging

    private func offset(of tab: AnalysisTab, slots: [AnalysisTab: (x: CGFloat, width: CGFloat)]) -> CGFloat {
        guard let drag, drag.tab == tab, let slot = slots[tab] else { return 0 }
        return drag.left - slot.x
    }

    private func reorderGesture(
        for tab: AnalysisTab,
        shown: [AnalysisTab],
        slots: [AnalysisTab: (x: CGFloat, width: CGFloat)]
    ) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let slot = slots[tab] else { return }
                var current = drag ?? TabDrag(tab: tab, grab: value.startLocation.x - slot.x, left: slot.x)
                if drag == nil, model.analysisTab != tab { select(tab) }
                let first = slots[shown.first ?? tab]?.x ?? Self.padding
                let last = shown.last.flatMap { slots[$0] }.map { $0.x + $0.width } ?? width
                current.left = min(max(value.location.x - current.grab, first), last - slot.width)
                drag = current
                reorderIfCrossed(current, shown: shown, slots: slots)
            }
            .onEnded { _ in
                withAnimation(settle) { drag = nil }
            }
    }

    /// Swaps the dragged tab with a neighbor once its middle passes the neighbor's.
    private func reorderIfCrossed(
        _ drag: TabDrag,
        shown: [AnalysisTab],
        slots: [AnalysisTab: (x: CGFloat, width: CGFloat)]
    ) {
        guard let index = shown.firstIndex(of: drag.tab), let slot = slots[drag.tab] else { return }
        let middle = drag.left + slot.width / 2
        var target: AnalysisTab?
        if index + 1 < shown.count, let next = slots[shown[index + 1]], middle > next.x + next.width / 2 {
            target = shown[index + 1]
        } else if index > 0, let previous = slots[shown[index - 1]], middle < previous.x + previous.width / 2 {
            target = shown[index - 1]
        }
        guard let target else { return }
        var layout = model.analysisTabs
        layout.move(drag.tab, onto: target)
        withAnimation(settle) { model.setAnalysisTabs(layout) }
    }

    // MARK: Fitting

    private func labelWidths(_ tabs: [AnalysisTab]) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: (11 * textScale).rounded(), weight: .medium)
        return tabs.map { tab in
            (NSLocalizedString(tab.title, comment: "Statistics tab") as NSString)
                .size(withAttributes: [.font: font]).width.rounded(.up)
        }
    }

    /// Each shown tab's leading edge and width in the bar, as the HStack lays them out.
    private func slots(for shown: [AnalysisTab]) -> [AnalysisTab: (x: CGFloat, width: CGFloat)] {
        var x = Self.padding
        var result: [AnalysisTab: (x: CGFloat, width: CGFloat)] = [:]
        for (tab, tabWidth) in zip(shown, labelWidths(shown)) {
            result[tab] = (x, tabWidth)
            x += tabWidth + Self.spacing
        }
        return result
    }

    /// The shown tabs that fit the bar's width, always including the active one, and the rest.
    private func fitting() -> (shown: [AnalysisTab], overflow: [AnalysisTab]) {
        let visible = model.analysisTabs.visible
        let available = width - 2 * Self.padding
        guard width > 0 else { return (visible, []) }
        let widths = labelWidths(visible)
        func total(_ count: Int) -> CGFloat {
            widths.prefix(count).reduce(0, +) + Self.spacing * CGFloat(max(count - 1, 0))
        }
        if total(visible.count) <= available { return (visible, []) }
        let room = available - (16 * textScale).rounded() - Self.spacing
        var count = visible.count - 1
        while count > 1, total(count) > room { count -= 1 }
        var shown = Array(visible.prefix(count))
        if let active = visible.firstIndex(of: model.analysisTab), active >= count {
            shown[shown.count - 1] = visible[active]
        }
        return (shown, visible.filter { !shown.contains($0) })
    }
}

/// Fixed weight so the active state never shifts layout.
private struct AnalysisTabButton: View {
    @Environment(\.neoTextScale) private var textScale

    let tab: AnalysisTab
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(tab.title))
                .neoFont(11, weight: .medium)
                .foregroundStyle(
                    isActive ? Color.accentColor : isHovering ? Color.primary : Color.secondary
                )
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if isActive {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(height: (2 * textScale).rounded())
                            .matchedGeometryEffect(id: "analysisTabUnderline", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Size-descending file list shared by the drill-ins and the Largest tab. Drill-ins pass onClose for
/// the back button.
struct StatsFileListView: View {
    let model: NeodiskViewModel
    /// Header title (localized key); nil while the list is still loading.
    let title: String?
    let swatch: Color?
    var backHelp: LocalizedStringKey = ""
    let isLoading: Bool
    let visibleIDs: [String]
    /// The rows' records when the list keeps its own; else `visibleIDs` resolve in the displayed tree.
    var rows: [FileNodeRecord]?
    let totalMatches: Int
    @Binding var filterText: String
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "chevron.left")
                            .neoFont(10, weight: .semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(backHelp)
                }

                if let title {
                    if let swatch {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(swatch)
                            .frame(width: 12, height: 12)
                    }
                    Text(LocalizedStringKey(title))
                        .neoFont(11, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Loading…")
                        .neoFont(11, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                TextField("Filter by name", text: $filterText)
                    .textFieldStyle(.plain)
                    .neoFont(11)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            if isLoading {
                Spacer()
                ProgressView().neoControlSize(base: .small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Only ids the store still resolves: a row with no node
                // would be an empty row.
                StatsListTable(
                    model: model,
                    rows: rows ?? visibleIDs.compactMap { model.store?.node(id: $0) },
                    click: .selectsNode { model.select($0) },
                    selectedID: model.selectedNodeID,
                    keepsLeaderInView: true
                ) { node in
                    FileResultRow(
                        node: node,
                        palette: model.vizPalette,
                        includeCloudOnly: model.showsCloudOnlyFiles,
                        cleanup: model.cleanup
                    )
                }

                if visibleIDs.count < totalMatches {
                    Divider()
                    Text(footerText)
                        .neoFont(10)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var footerText: String {
        let shown = visibleIDs.count.formatted()
        let total = totalMatches.formatted()
        let format = filterText.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSLocalizedString("Largest %@ of %@ — search to narrow", comment: "File list footer, no filter")
            : NSLocalizedString("Top %@ of %@ matches — refine to narrow", comment: "File list footer, filtered")
        return String(format: format, shown, total)
    }
}
