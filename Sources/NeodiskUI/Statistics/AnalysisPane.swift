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
        // Right-clicking anywhere without its own menu brings hidden tabs back.
        .contextMenu { AnalysisTabsMenuItems(model: model) }
    }
}

/// Size-descending file list shared by the drill-ins and the Largest tab. Drill-ins pass onClose for
/// the back button.
struct StatsFileListView: View {
    let model: NeodiskViewModel
    /// Header title (localized key); nil while the list is still loading. Only a drill-in (`onClose`) has the
    /// header: the Largest tab's list is named by the tab.
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
            if let onClose {
                drillInHeader(onClose)
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                TextField("Filter by name", text: $filterText)
                    .textFieldStyle(.plain)
                    .neoFont(11)
                    // Esc clears the filter, then leaves a drill-in.
                    .onExitCommand {
                        if !filterText.isEmpty {
                            filterText = ""
                        } else {
                            onClose?()
                        }
                    }
            }
            .padding(.horizontal, StatsListMetrics.inset)
            .padding(.vertical, 6)

            Divider()

            if isLoading {
                Spacer()
                ProgressView().neoControlSize(base: .small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if totalMatches == 0, !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
                StatsEmptyState(symbol: "magnifyingglass", message: Text("No matches"))
            } else if totalMatches == 0, model.coordinator.snapshot?.isComplete == true {
                StatsEmptyState.noFiles
            } else {
                // Only ids the store still resolves: a row with no node
                // would be an empty row.
                StatsListTable(
                    model: model,
                    rows: rows ?? visibleIDs.compactMap { model.store?.node(id: $0) },
                    click: .selectsNode { model.select($0) },
                    selection: model.selection,
                    keepsLeaderInView: true,
                    onCancel: onClose
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
                        .padding(.horizontal, StatsListMetrics.inset)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func drillInHeader(_ onClose: @escaping () -> Void) -> some View {
        DrillInBackButton(help: backHelp, action: onClose) {
            if let title {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(swatch)
                        .frame(width: 12, height: 12)
                }
                Text(LocalizedStringKey(title))
                    .neoFont(11, weight: .semibold)
                    .lineLimit(1)
            } else {
                Text("Loading…")
                    .neoFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, StatsListMetrics.inset)
        .padding(.top, 3)
    }

    /// Plain counts, like the Changes tab's footer: the filter field is the way to narrow.
    private var footerText: String {
        let total = totalMatches.formatted()
        return filterText.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(
                format: NSLocalizedString("Top %@ of %@ files", comment: "File list footer, no filter"),
                visibleIDs.count.formatted(), total
            )
            : String(
                format: NSLocalizedString("Top %lld of %@ matches", comment: "File list footer, filtered"),
                Int64(visibleIDs.count), total
            )
    }

}

/// A drill-in's way back: the chevron and the title beside it are one target the header's whole height, as a
/// back button in a navigation bar is, and the chevron brightens under the pointer. Esc does the same (the list
/// and the filter field handle it).
struct DrillInBackButton<Title: View>: View {
    let help: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let title: Title
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .neoFont(10, weight: .semibold)
                    .foregroundStyle(isHovered ? .primary : .secondary)
                title
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
