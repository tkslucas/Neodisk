// The active tab decides what treemap color means (see NeodiskViewModel.vizColorMode).

import SwiftUI
import NeodiskKit

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
    @Namespace private var underlineNamespace

    var body: some View {
        VStack(spacing: 0) {
            // Text tabs, not a segmented picker: bezel padding truncates four localized titles at the default
            // width.
            HStack(spacing: 12) {
                ForEach(AnalysisTab.allCases) { tab in
                    AnalysisTabButton(
                        tab: tab,
                        isActive: model.analysisTab == tab,
                        namespace: underlineNamespace
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            model.analysisTab = tab
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)

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

/// Fixed weight so the active state never shifts layout, and fixed size so narrow panes truncate
/// instead of rendering tabs at mismatched scales.
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
                        includeCloudOnly: model.showsCloudOnlyFiles
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
