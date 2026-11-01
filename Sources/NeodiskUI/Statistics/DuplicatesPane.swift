// Hashing reads real bytes, so duplicates are found only on an explicit action. A copy's row selects it, and
// drags or ⌘⌫ collect it in Cleanup.

import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct DuplicatesPane: View {
    let model: NeodiskViewModel

    var body: some View {
        Group {
            if let group = model.duplicates.openGroup {
                DuplicateGroupDetailView(model: model, group: group)
            } else {
                switch model.duplicates.phase {
                case .idle:
                    idleView
                case .scanning:
                    scanningView
                case .failed(let message):
                    failedView(message)
                case .finished(let results):
                    DuplicateResultsView(model: model, results: results)
                }
            }
        }
        // Fill an idle tab from a persisted result when it comes on screen or a
        // new snapshot lands; a hit shows the previous run without re-hashing.
        .task(id: loadTaskID) {
            model.duplicates.loadIfNeeded()
        }
    }

    private var loadTaskID: String {
        model.coordinator.snapshot?.id.uuidString ?? "none"
    }

    private var idleView: some View {
        StatsEmptyState(
            symbol: "doc.on.doc",
            title: Text("Find files with identical content"),
            message: Text(explainerText)
        ) {
            Button {
                model.duplicates.startScan()
            } label: {
                Text("Find Duplicates").neoFont(11)
            }
            .neoControlSize(base: .small)
            .buttonStyle(.borderedProminent)
            .disabled(!model.duplicates.canScan)
            .padding(.top, 2)
        }
    }

    private var explainerText: String {
        String(
            format: NSLocalizedString(
                "Compares files larger than %@ and groups identical copies.",
                comment: "Duplicates tab explainer; %@ is the minimum file size"
            ),
            NeodiskFormatters.size(DuplicateFinder.defaultMinimumFileSize)
        )
    }

    /// Results render as they confirm, so scanning feels live like the map rather than a loading bar.
    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(liveSummaryText)
                        .neoFont(11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(scanningStatusText)
                        .neoFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    model.duplicates.cancelScan()
                } label: {
                    Text("Cancel").neoFont(11)
                }
                .neoControlSize(base: .small)
            }
            .padding(.horizontal, StatsListMetrics.inset)
            .padding(.vertical, 7)

            Divider()

            if model.duplicates.liveGroups.isEmpty {
                Spacer()
                Text("No duplicates found yet")
                    .neoFont(11)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                DuplicateGroupList(model: model, groups: model.duplicates.liveGroups)
            }
        }
    }

    private var liveSummaryText: String {
        AppStrings.plural(
            model.duplicates.liveGroups.count, one: "%@ group · %@ wasted", other: "%@ groups · %@ wasted",
            model.duplicates.liveGroups.count.formatted(),
            NeodiskFormatters.size(model.duplicates.liveGroups.reduce(0) { $0 + $1.reclaimableBytes })
        )
    }

    private var scanningStatusText: String {
        String(
            format: NSLocalizedString(
                "Searching for duplicates… %@",
                comment: "Duplicates tab header while scanning; %@ is a percentage"
            ),
            model.duplicates.progress.formatted(.percent.precision(.fractionLength(0)))
        )
    }

    private func failedView(_ message: String) -> some View {
        StatsEmptyState(
            symbol: "exclamationmark.triangle",
            symbolSize: 24,
            message: Text(message)
        ) {
            Button {
                model.duplicates.startScan()
            } label: {
                Text("Try Again").neoFont(11)
            }
            .neoControlSize(base: .small)
        }
    }
}

private struct DuplicateResultsView: View {
    let model: NeodiskViewModel
    let results: DuplicateScanResults

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryText)
                        .neoFont(11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let computedText {
                        Text(computedText)
                            .neoFont(10)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    model.duplicates.startScan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .neoFont(10, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!model.duplicates.canScan)
                .neoHelp("Search for duplicates again")
            }
            .padding(.horizontal, StatsListMetrics.inset)
            .padding(.vertical, 7)

            Divider()

            if results.groups.isEmpty {
                Spacer()
                Text("No duplicates found")
                    .neoFont(11)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                DuplicateGroupList(model: model, groups: results.groups)
            }

            if results.unreadableCount > 0 {
                Divider()
                Text(unreadableText)
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, StatsListMetrics.inset)
                    .padding(.vertical, 4)
            }
        }
    }

    private var summaryText: String {
        AppStrings.plural(
            results.groups.count, one: "%@ group · %@ wasted", other: "%@ groups · %@ wasted",
            results.groups.count.formatted(),
            NeodiskFormatters.size(results.totalWastedBytes)
        )
    }

    /// Makes the age of what's on screen clear, so Refresh has an obvious meaning.
    private var computedText: String? {
        guard let computedAt = model.duplicates.computedAt else { return nil }
        return String(
            format: NSLocalizedString(
                "Duplicates computed %@",
                comment: "Duplicates results header; %@ is a relative date"
            ),
            DisplayFormatters.relativeDate(computedAt)
        )
    }

    private var unreadableText: String {
        AppStrings.plural(
            results.unreadableCount, one: "%@ file couldn't be read", other: "%@ files couldn't be read",
            results.unreadableCount.formatted()
        )
    }
}

/// Groups largest waste first; clicking one opens its copies.
private struct DuplicateGroupList: View {
    let model: NeodiskViewModel
    let groups: [DuplicateGroup]

    var body: some View {
        StatsListTable(
            model: model,
            rows: groups,
            click: .opens { id in
                if let group = groups.first(where: { $0.id == id }) {
                    model.duplicates.open(group)
                }
            }
        ) { group in
            DuplicateGroupRow(model: model, group: group)
                .neoHelp("Show the copies in this group")
        }
    }
}

private struct DuplicateGroupRow: View {
    let model: NeodiskViewModel
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 6) {
            if let node = representativeNode {
                FileCategoryIcon(node: node, palette: model.vizPalette)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(copiesText)
                    .foregroundStyle(.secondary)
                    .neoFont(10)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            // Pure APFS-clone groups share their blocks, so removing a copy
            // frees ~nothing: label them instead of showing a misleading 0.
            if group.isAllClones {
                Text("APFS clones")
                    .foregroundStyle(.secondary)
                    .neoFont(10)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(NeodiskFormatters.size(group.reclaimableBytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .neoFont(12)
    }

    /// Every copy in a group has identical content, so the first resolvable
    /// node stands in for the group's type icon.
    private var representativeNode: FileNodeRecord? {
        guard let id = group.nodeIDs.first else { return nil }
        return model.store?.node(id: id)
    }

    private var displayName: String {
        guard let id = group.nodeIDs.first else { return "" }
        return representativeNode?.name ?? (id as NSString).lastPathComponent
    }

    private var copiesText: String {
        String(
            format: NSLocalizedString(
                "%@ copies × %@",
                comment: "Duplicate group row subtitle: copy count, size per copy"
            ),
            group.nodeIDs.count.formatted(),
            NeodiskFormatters.size(group.fileSize)
        )
    }
}

/// Drill-in from a group row: every copy, selectable like the other file
/// lists — clicking a row selects it in the outline and treemap.
private struct DuplicateGroupDetailView: View {
    let model: NeodiskViewModel
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DrillInBackButton(help: "Back to duplicates") {
                model.duplicates.closeGroup()
            } title: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .neoFont(11, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitleText)
                        .neoFont(10)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, StatsListMetrics.inset)
            .padding(.vertical, 3)

            Divider()

            StatsListTable(
                model: model,
                rows: group.nodeIDs.compactMap { model.store?.node(id: $0) },
                click: .selectsNode { model.select($0) },
                selection: model.selection,
                onCancel: { model.duplicates.closeGroup() }
            ) { node in
                FileResultRow(
                    node: node,
                    palette: model.vizPalette,
                    includeCloudOnly: model.showsCloudOnlyFiles,
                    cleanup: model.cleanup
                )
            }
        }
    }

    private var displayName: String {
        guard let id = group.nodeIDs.first else { return "" }
        return model.store?.node(id: id)?.name ?? (id as NSString).lastPathComponent
    }

    private var subtitleText: String {
        let copies = String(
            format: NSLocalizedString(
                "%@ copies × %@",
                comment: "Duplicate group row subtitle: copy count, size per copy"
            ),
            group.nodeIDs.count.formatted(),
            NeodiskFormatters.size(group.fileSize)
        )
        let reclaim = group.isAllClones
            ? NSLocalizedString("APFS clones", comment: "Duplicate group note: copies are APFS clones that free no space")
            : String(
                format: NSLocalizedString("%@ wasted", comment: "Duplicate group detail: reclaimable size"),
                NeodiskFormatters.size(group.reclaimableBytes)
            )
        return "\(copies) — \(reclaim)"
    }
}
