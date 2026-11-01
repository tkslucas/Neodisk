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

/// A segmented control while every shown tab fits its full title, else a pop-up of them: titles never truncate,
/// whatever the pane's width, language or text size. Right-click chooses which tabs show; hiding some lets the
/// segmented control fit a narrower pane.
struct AnalysisTabBar: View {
    let model: NeodiskViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            AnalysisSegmentedControl(tabs: model.analysisTabs.visible, selection: model.analysisTab) {
                model.analysisTab = $0
            }
            Picker("Statistics", selection: Binding(get: { model.analysisTab }, set: { model.analysisTab = $0 })) {
                ForEach(model.analysisTabs.visible) { tab in
                    Text(LocalizedStringKey(tab.title)).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .neoControlSize(base: .small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
        .contextMenu { visibilityMenu }
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
        Button("Reset Tabs") { model.setAnalysisTabs(ItemLayout()) }
            .disabled(layout.isStandard)
    }
}

/// Segments as wide as their titles, not all as wide as the widest, so the control fits the narrowest pane it can;
/// it stretches proportionally to fill the rest.
private struct AnalysisSegmentedControl: NSViewRepresentable {
    let tabs: [AnalysisTab]
    let selection: AnalysisTab
    let select: (AnalysisTab) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillProportionally
        control.target = context.coordinator
        control.action = #selector(Coordinator.picked(_:))
        control.setAccessibilityLabel(NSLocalizedString("Statistics", comment: "Statistics tabs"))
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.control = self
        let size = NSControl.ControlSize(context.environment.controlSize)
        if control.controlSize != size {
            control.controlSize = size
            control.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        }
        if control.segmentCount != tabs.count || context.coordinator.tabs != tabs {
            context.coordinator.tabs = tabs
            control.segmentCount = tabs.count
            for (index, tab) in tabs.enumerated() {
                control.setLabel(NSLocalizedString(tab.title, comment: "Statistics tab"), forSegment: index)
            }
        }
        control.selectedSegment = tabs.firstIndex(of: selection) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let fitting = nsView.intrinsicContentSize
        return CGSize(width: max(proposal.width ?? fitting.width, fitting.width), height: fitting.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var control: AnalysisSegmentedControl?
        var tabs: [AnalysisTab] = []

        @objc func picked(_ sender: NSSegmentedControl) {
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            control?.select(tabs[sender.selectedSegment])
        }
    }
}

private extension NSControl.ControlSize {
    init(_ size: ControlSize) {
        switch size {
        case .mini: self = .mini
        case .small: self = .small
        case .large: self = .large
        case .extraLarge: self = .large
        default: self = .regular
        }
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
