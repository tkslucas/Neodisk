//
//  AnalysisPane.swift
//  Neodisk
//
//  The right-hand statistics panel: a tab per analysis lens (file kinds,
//  modification age), each pairing a legend/stats list with the treemap —
//  the active tab decides what treemap color means (see
//  NeodiskViewModel.treemapColorMode) and drill-ins highlight the map.
//

import SwiftUI
import NeodiskKit

enum AnalysisTab: String, CaseIterable, Identifiable, Sendable {
    case largest
    case kinds
    case age
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largest: return "Largest"
        case .kinds: return "Kinds"
        case .age: return "Age"
        case .duplicates: return "Duplicates"
        }
    }
}

struct AnalysisPane: View {
    let model: NeodiskViewModel
    @Namespace private var underlineNamespace

    var body: some View {
        VStack(spacing: 0) {
            // Flat text tabs instead of a segmented picker: four localized
            // segment titles don't fit the pane's width range (the bezel
            // padding truncates them even in English at the default width),
            // while bare text does.
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
            }
        }
    }
}

/// One flat text tab: fixed .medium weight so the active state (accent
/// color + sliding underline) never shifts the row's layout, and a small
/// scale floor so long localized titles compress a touch at the pane's
/// minimum width instead of truncating.
private struct AnalysisTabButton: View {
    let tab: AnalysisTab
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(tab.title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    isActive ? Color.accentColor : isHovering ? Color.primary : Color.secondary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if isActive {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(height: 2)
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

/// Size-descending file list shared by the statistics tabs — the drill-ins
/// (every file of one kind, every file modified in one period) and the
/// Largest tab's whole-scan list: header with a color swatch, fuzzy filter
/// field, and the file list. Drill-ins pass onClose for the back button;
/// top-level lists omit it. Read-only navigation — clicking a row selects
/// the node in the outline and treemap.
struct StatsFileListView: View {
    let model: NeodiskViewModel
    /// Header title (localized key); nil while the list is still loading.
    let title: String?
    let swatch: Color?
    var backHelp: LocalizedStringKey = ""
    let isLoading: Bool
    let visibleIDs: [String]
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
                            .font(.system(size: 10, weight: .semibold))
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
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Loading…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Filter by name", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            if isLoading {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                let selection = Binding<String?>(
                    get: { model.selectedNodeID },
                    set: { if let id = $0 { model.select(id) } }
                )
                List(visibleIDs, id: \.self, selection: selection) { nodeID in
                    if let node = model.store?.node(id: nodeID) {
                        FileResultRow(node: node)
                            .listRowSeparator(.hidden)
                    }
                }
                .fileNodeActions(model: model)
                .environment(\.defaultMinListRowHeight, 20)
                .quickLookOnSpace(model: model)

                if visibleIDs.count < totalMatches {
                    Divider()
                    Text(footerText)
                        .font(.system(size: 10))
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
