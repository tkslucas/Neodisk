//
//  DuplicatesPane.swift
//  Neodisk
//
//  The statistics panel's Duplicates tab: an explicit "Find Duplicates"
//  action (hashing reads real bytes, so it never runs unasked), then the
//  confirmed groups sorted by reclaimable space — streaming in live while
//  the scan runs, complete once it finishes. Selecting
//  a group lights its copies on the treemap; rows are read-only navigation —
//  cleanup happens via Reveal in Finder.
//

import SwiftUI
import NeodiskKit

struct DuplicatesPane: View {
    let model: NeodiskViewModel

    var body: some View {
        Group {
            if let group = model.duplicates.openGroup {
                DuplicateGroupDetailView(model: model, group: group)
            } else {
                switch model.duplicates.phase {
                case .idle:
                    if isCloudSnapshot {
                        cloudUnavailableView
                    } else {
                        idleView
                    }
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

    /// A cloud snapshot's nodes are remote entries, not on-disk files the
    /// hasher can read, so the tab shows an explanation instead of a scan
    /// button that would do nothing.
    private var isCloudSnapshot: Bool {
        model.coordinator.snapshot?.target.kind == .cloud
    }

    private var cloudUnavailableView: some View {
        StatsEmptyState(
            symbol: "cloud",
            title: Text("Duplicate detection isn't available for cloud drives"),
            message: Text("Finding duplicates reads each file's contents, which only works for files stored on this Mac.")
        )
    }

    private var idleView: some View {
        StatsEmptyState(
            symbol: "doc.on.doc",
            title: Text("Find files with identical content"),
            message: Text(explainerText)
        ) {
            Button("Find Duplicates") {
                model.duplicates.startScan()
            }
            .controlSize(.small)
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

    /// Results render as they confirm — the same header and rows as the
    /// finished list, with a cancel action and a progress readout instead of
    /// the computed-at banner and refresh — so scanning feels like the map:
    /// live, not a loading bar.
    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(liveSummaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(scanningStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    model.duplicates.cancelScan()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            if model.duplicates.liveGroups.isEmpty {
                Spacer()
                Text("No duplicates found yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.duplicates.liveGroups) { group in
                    DuplicateGroupRow(model: model, group: group)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.duplicates.open(group)
                        }
                        .help("Show the copies in this group")
                }
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private var liveSummaryText: String {
        String(
            format: NSLocalizedString(
                "%@ groups · %@ wasted",
                comment: "Duplicates results header: group count, reclaimable size"
            ),
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
            Button("Try Again") {
                model.duplicates.startScan()
            }
            .controlSize(.small)
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let computedText {
                        Text(computedText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    model.duplicates.startScan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!model.duplicates.canScan)
                .help("Search for duplicates again")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            if results.groups.isEmpty {
                Spacer()
                Text("No duplicates found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(results.groups) { group in
                    DuplicateGroupRow(model: model, group: group)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.duplicates.open(group)
                        }
                        .help("Show the copies in this group")
                }
                .environment(\.defaultMinListRowHeight, 20)
            }

            if results.unreadableCount > 0 {
                Divider()
                Text(unreadableText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }

    private var summaryText: String {
        String(
            format: NSLocalizedString(
                "%@ groups · %@ wasted",
                comment: "Duplicates results header: group count, reclaimable size"
            ),
            results.groups.count.formatted(),
            NeodiskFormatters.size(results.totalWastedBytes)
        )
    }

    /// "Duplicates computed 3 minutes ago" — shown once a run is finished (a
    /// fresh scan or a result loaded from cache), so the age of what's on
    /// screen is clear and Refresh has an obvious meaning.
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
        String(
            format: NSLocalizedString(
                "%@ files couldn't be read",
                comment: "Duplicates results footer"
            ),
            results.unreadableCount.formatted()
        )
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
                    .font(.system(size: 10))
            }

            Spacer(minLength: 8)

            // Pure APFS-clone groups share their blocks, so removing a copy
            // frees ~nothing: label them instead of showing a misleading 0.
            if group.isAllClones {
                Text("APFS clones")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(NeodiskFormatters.size(group.reclaimableBytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 12))
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
            HStack(spacing: 6) {
                Button {
                    model.duplicates.closeGroup()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to duplicates")

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            let selection = Binding<String?>(
                get: { model.selectedNodeID },
                set: { if let id = $0 { model.select(id) } }
            )
            List(group.nodeIDs, id: \.self, selection: selection) { nodeID in
                if let node = model.store?.node(id: nodeID) {
                    FileResultRow(
                        node: node,
                        palette: model.vizPalette,
                        includeCloudOnly: model.showsCloudOnlyFiles
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .fileNodeActions(model: model)
            .environment(\.defaultMinListRowHeight, 20)
            .quickLookOnSpace(model: model)
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
