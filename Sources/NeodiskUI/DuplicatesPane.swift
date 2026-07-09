//
//  DuplicatesPane.swift
//  Neodisk
//
//  The statistics panel's Duplicates tab: an explicit "Find Duplicates"
//  action (hashing reads real bytes, so it never runs unasked), hashing
//  progress, and the confirmed groups sorted by reclaimable space. Selecting
//  a group lights its copies on the treemap; rows are read-only navigation —
//  cleanup happens via Reveal in Finder.
//

import SwiftUI
import NeodiskKit

struct DuplicatesPane: View {
    let model: NeodiskViewModel

    var body: some View {
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

    private var idleView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Find files with identical content")
                .font(.system(size: 12, weight: .semibold))
            Text(explainerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Find Duplicates") {
                model.duplicates.startScan()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!model.duplicates.canScan)
            .padding(.top, 2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
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

    private var scanningView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView(value: model.duplicates.progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 4)
            Text("Searching for duplicates…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Cancel") {
                model.duplicates.cancelScan()
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                model.duplicates.startScan()
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

private struct DuplicateResultsView: View {
    let model: NeodiskViewModel
    let results: DuplicateScanResults

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(summaryText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

            Text(NeodiskFormatters.size(group.wastedBytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
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
                    FileResultRow(node: node, palette: model.vizPalette)
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
        let wasted = String(
            format: NSLocalizedString("%@ wasted", comment: "Duplicate group detail: reclaimable size"),
            NeodiskFormatters.size(group.wastedBytes)
        )
        return "\(copies) — \(wasted)"
    }
}
