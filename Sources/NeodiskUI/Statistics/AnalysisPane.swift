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
/// menu instead of truncating; right-click shows or hides them, and dragging one reorders them.
private struct AnalysisTabBar: View {
    let model: NeodiskViewModel

    @Namespace private var underlineNamespace
    @Environment(\.neoTextScale) private var textScale
    @State private var width: CGFloat = 0
    @State private var dragged: AnalysisTab?

    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 10

    var body: some View {
        let (shown, overflow) = fitting()
        HStack(spacing: Self.spacing) {
            ForEach(shown) { tab in
                AnalysisTabButton(
                    tab: tab,
                    isActive: model.analysisTab == tab,
                    namespace: underlineNamespace
                ) {
                    select(tab)
                }
                .onDrag {
                    dragged = tab
                    return NSItemProvider(object: tab.rawValue as NSString)
                }
                .onDrop(of: [.plainText], delegate: TabReorderDelegate(target: tab, dragged: $dragged, model: model))
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .contextMenu { visibilityMenu }
        .animation(.easeInOut(duration: 0.15), value: model.analysisTabs)
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
                    model.setAnalysisTabs(updated)
                }
            ))
            .disabled(!layout.isHidden(tab) && !layout.canHide(tab))
        }
        Divider()
        Button("Reset Tabs") {
            model.setAnalysisTabs(ItemLayout())
        }
        .disabled(layout.isStandard)
    }

    private func select(_ tab: AnalysisTab) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.analysisTab = tab
        }
    }

    /// The shown tabs that fit the bar's width, always including the active one, and the rest.
    private func fitting() -> (shown: [AnalysisTab], overflow: [AnalysisTab]) {
        let visible = model.analysisTabs.visible
        let available = width - 2 * Self.padding
        guard width > 0 else { return (visible, []) }
        let font = NSFont.systemFont(ofSize: (11 * textScale).rounded(), weight: .medium)
        let widths = visible.map { tab in
            (NSLocalizedString(tab.title, comment: "Statistics tab") as NSString)
                .size(withAttributes: [.font: font]).width.rounded(.up)
        }
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

/// Moves the dragged tab into each tab's place as it passes over, so the bar reorders under the pointer.
private struct TabReorderDelegate: DropDelegate {
    let target: AnalysisTab
    @Binding var dragged: AnalysisTab?
    let model: NeodiskViewModel

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        var layout = model.analysisTabs
        layout.move(dragged, onto: target)
        model.setAnalysisTabs(layout)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragged == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragged = nil }
        return dragged != nil
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
