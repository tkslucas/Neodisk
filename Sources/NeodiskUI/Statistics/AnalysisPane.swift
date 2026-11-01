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
struct AnalysisTabBar: View {
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
        let strip = strip
        let (shown, overflow) = fitting(strip)
        HStack(spacing: Self.spacing) {
            ForEach(shown) { tab in
                AnalysisTabButton(
                    tab: tab,
                    isActive: model.analysisTab == tab,
                    namespace: underlineNamespace
                ) {
                    select(tab)
                }
                .offset(x: offset(of: tab, in: shown, strip: strip))
                .zIndex(drag?.tab == tab ? 1 : 0)
                .transaction { if drag?.tab == tab { $0.animation = nil } }
                .simultaneousGesture(reorderGesture(for: tab))
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
                        .foregroundStyle(.secondary)
                        .frame(height: 20 * textScale)
                        .contentShape(Rectangle())
                }
                // A plain button, so the chevron draws in the inactive tabs' gray and scales with them.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
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

    private func offset(of tab: AnalysisTab, in shown: [AnalysisTab], strip: TabStrip<AnalysisTab>) -> CGFloat {
        guard let drag, drag.tab == tab, let slot = strip.slots(shown)[tab] else { return 0 }
        return drag.left - slot
    }

    /// Reads the bar afresh on every update rather than capturing it: each swap changes the slots.
    private func reorderGesture(for tab: AnalysisTab) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let strip = strip
                let (shown, overflow) = fitting(strip)
                guard let slot = strip.slots(shown)[tab] else { return }
                // A drag of another tab that never ended (its tab left the bar mid-drag) doesn't carry over.
                var current = TabDrag(tab: tab, grab: value.startLocation.x - slot, left: slot)
                if let drag, drag.tab == tab {
                    current = drag
                } else if model.analysisTab != tab {
                    select(tab)
                }
                current.left = strip.clampedLeft(value.location.x - current.grab, of: tab, in: shown)
                drag = current
                let order = strip.reordered(shown, dragging: tab, left: current.left)
                guard order != shown else { return }
                // The » menu's tabs follow the shown ones, so a tab shown out of order stays where it was dropped.
                var layout = model.analysisTabs
                layout.setVisibleOrder(order + overflow)
                withAnimation(settle) { model.setAnalysisTabs(layout) }
            }
            .onEnded { _ in
                withAnimation(settle) { drag = nil }
            }
    }

    // MARK: Fitting

    /// Measured in the font the tabs draw with, so the slots match the laid-out tabs.
    private var strip: TabStrip<AnalysisTab> {
        let font = NSFont.systemFont(ofSize: 11 * textScale, weight: .medium)
        let widths = Dictionary(uniqueKeysWithValues: AnalysisTab.allCases.map { tab in
            (tab, (NSLocalizedString(tab.title, comment: "Statistics tab") as NSString)
                .size(withAttributes: [.font: font]).width)
        })
        return TabStrip(padding: Self.padding, spacing: Self.spacing, widths: widths)
    }

    /// The shown tabs that fit the bar's width, always including the active one, and the rest.
    private func fitting(_ strip: TabStrip<AnalysisTab>) -> (shown: [AnalysisTab], overflow: [AnalysisTab]) {
        strip.fit(
            model.analysisTabs.visible, barWidth: width,
            menuWidth: (16 * textScale).rounded(), active: model.analysisTab
        )
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
