//
//  ChangesPane.swift
//  Neodisk
//
//  The statistics panel's Changes tab: what this scan added, deleted,
//  renamed, grew, or shrank against the previous scan of the same location,
//  biggest disk movement first. Rows are the shared read-only navigation —
//  clicking selects the node in the outline and treemap; deleted entries
//  (whose node no longer exists) select the nearest surviving ancestor
//  instead. Availability mirrors the outline diff: no list
//  without a previous snapshot to compare against.
//

import SwiftUI
import NeodiskKit

struct ChangesPane: View {
    let model: NeodiskViewModel

    var body: some View {
        Group {
            if let list = model.changes.list {
                ChangeResultsView(model: model, list: list)
            } else if model.changes.isLoading {
                loadingView
            } else {
                emptyView
            }
        }
        // Covers every way the list goes stale while the tab is on screen:
        // switching to the tab (appear), a new snapshot landing (id), the
        // previous snapshot rotating under the same tree (reloadToken), and
        // the comparison becoming possible (canCompare flips after the
        // first save of a previously unscanned location).
        .task(id: loadTaskID) {
            model.changes.loadIfNeeded()
        }
    }

    private var loadTaskID: String {
        let snapshotID = model.coordinator.snapshot?.id.uuidString ?? "none"
        return "\(snapshotID)|\(model.changes.reloadToken)|\(model.changes.canCompare)"
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Comparing with the previous scan…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        StatsEmptyState(
            symbol: "plus.forwardslash.minus",
            title: Text("No previous scan to compare"),
            message: Text("Scan this location again and what was added, deleted, renamed, or resized will appear here.")
        )
    }
}

private struct ChangeResultsView: View {
    let model: NeodiskViewModel
    let list: ScanChangeList

    var body: some View {
        @Bindable var changes = model.changes
        let filter = model.changes.filter
        let entries = list.entries(for: filter)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sinceText)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(summaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            // Own centered row: beside the header it starved the "since"
            // text into truncation at everyday panel widths.
            Picker("", selection: $changes.filter) {
                ForEach(ScanChangeList.Filter.allCases) { filter in
                    Text(LocalizedStringKey(filter.title)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider()

            if entries.isEmpty {
                Spacer()
                Text(emptyText(for: filter))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                // Selection by entry ID: for live entries that is the node ID
                // (context menu and Quick Look work through the node lookup);
                // a deleted entry's ID is its old path — absent from the
                // store, so those helpers no-op and the click handler routes
                // to the nearest surviving ancestor.
                let selection = Binding<String?>(
                    get: { model.selectedNodeID },
                    set: { if let id = $0 { select(entryID: id) } }
                )
                List(entries, selection: selection) { entry in
                    ChangeEntryRow(model: model, entry: entry)
                        .listRowSeparator(.hidden)
                }
                .fileNodeActions(model: model)
                .environment(\.defaultMinListRowHeight, 20)
                .quickLookOnSpace(model: model)

                if entries.count < list.totalCount(for: filter) {
                    Divider()
                    Text(footerText(entries: entries, filter: filter))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func emptyText(for filter: ScanChangeList.Filter) -> LocalizedStringKey {
        switch filter {
        case .all: return "No changes since the previous scan"
        case .added: return "Nothing added since the previous scan"
        case .deleted: return "Nothing deleted since the previous scan"
        }
    }

    /// Live entries select their node; deleted entries reveal where the
    /// item used to live by selecting the deepest ancestor that survived.
    private func select(entryID: String) {
        guard let store = model.store else { return }
        if store.node(id: entryID) != nil {
            model.select(entryID)
            return
        }
        var path = entryID
        while path.count > 1 {
            path = (path as NSString).deletingLastPathComponent
            if store.node(id: path) != nil {
                model.select(path)
                return
            }
        }
    }

    private var sinceText: String {
        guard let comparisonDate = model.changes.comparisonDate else {
            return NSLocalizedString("Changes since the previous scan", comment: "Changes tab header")
        }
        return String(
            format: NSLocalizedString("Changes since %@", comment: "Changes tab header; %@ is a relative date"),
            DisplayFormatters.relativeDate(comparisonDate)
        )
    }

    private var summaryText: String {
        String(
            format: NSLocalizedString(
                "%@ added · %@ deleted · %@ renamed",
                comment: "Changes tab summary: bytes added, bytes deleted, rename count"
            ),
            NeodiskFormatters.size(list.addedBytes),
            NeodiskFormatters.size(list.removedBytes),
            list.renamedCount.formatted()
        )
    }

    private func footerText(entries: [ScanChangeEntry], filter: ScanChangeList.Filter) -> String {
        String(
            format: NSLocalizedString("Top %@ of %@ changes", comment: "Changes tab footer"),
            entries.count.formatted(),
            list.totalCount(for: filter).formatted()
        )
    }
}

extension ScanChangeList.Filter {
    /// Segmented-control title; "Added"/"Deleted" reuse the row-kind keys.
    var title: String {
        switch self {
        case .all: return "All"
        case .added: return "Added"
        case .deleted: return "Deleted"
        }
    }
}

private struct ChangeEntryRow: View {
    let model: NeodiskViewModel
    let entry: ScanChangeEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kindSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(kindColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitleText)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if entry.delta == 0 {
                // An equal-size rename: the size says more than a delta dot.
                Text(NeodiskFormatters.size(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                DeltaLabel(delta: entry.delta)
            }
        }
        .font(.system(size: 12))
        .help(helpText)
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .added: return "plus.circle"
        case .deleted: return "minus.circle"
        case .renamed: return "arrow.right.circle"
        case .grown: return "arrow.up.circle"
        case .shrunk: return "arrow.down.circle"
        }
    }

    /// The outline diff's color language: red took disk space, green gave
    /// it back, neutral for pure moves.
    private var kindColor: Color {
        switch entry.kind {
        case .added, .grown: return .red
        case .deleted, .shrunk: return .green
        case .renamed: return .secondary
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .grown: return "Grown"
        case .shrunk: return "Shrunk"
        }
    }

    private var subtitleText: String {
        if entry.kind == .renamed, let previousPath = entry.previousPath {
            return String(
                format: NSLocalizedString("Was %@", comment: "Changes tab renamed row; %@ is the old path"),
                DisplayFormatters.displayPath(previousPath)
            )
        }
        let kind = NSLocalizedString(kindLabel, comment: "Changes tab row kind")
        let folder = (DisplayFormatters.displayPath(entry.path) as NSString).deletingLastPathComponent
        return "\(kind) — \(folder)"
    }

    private var helpText: String {
        let path = DisplayFormatters.displayPath(entry.path)
        guard entry.kind == .renamed, let previousPath = entry.previousPath else { return path }
        return "\(DisplayFormatters.displayPath(previousPath)) → \(path)"
    }
}
