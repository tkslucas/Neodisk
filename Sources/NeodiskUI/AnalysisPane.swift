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
    case kinds
    case age

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kinds: return "Kinds"
        case .age: return "Age"
        }
    }
}

struct AnalysisPane: View {
    let model: NeodiskViewModel

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("", selection: $model.analysisTab) {
                ForEach(AnalysisTab.allCases) { tab in
                    Text(LocalizedStringKey(tab.title)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            switch model.analysisTab {
            case .kinds:
                KindStatsPane(model: model)
            case .age:
                AgeStatsPane(model: model)
            }
        }
    }
}

/// Drill-in file list shared by the statistics tabs (every file of one kind,
/// every file modified in one period): back header with a color swatch,
/// fuzzy filter field, and the size-descending file list. Read-only
/// navigation — clicking a row selects the node in the outline and treemap.
struct StatsFileListView: View {
    let model: NeodiskViewModel
    /// Header title (localized key); nil while the list is still loading.
    let title: String?
    let swatch: Color?
    let backHelp: LocalizedStringKey
    let isLoading: Bool
    let visibleIDs: [String]
    let totalMatches: Int
    @Binding var filterText: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(backHelp)

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
                            .contextMenu {
                                if node.supportsFileActions {
                                    Button("Reveal in Finder") { model.reveal(node) }
                                    Button("Open") { model.open(node) }
                                    Button("Copy Path") { model.copyPath(node) }
                                }
                            }
                    }
                }
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
