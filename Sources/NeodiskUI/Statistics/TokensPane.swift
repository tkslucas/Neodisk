//
//  TokensPane.swift
//  Neodisk
//
//  The statistics panel in token mode: totals for the scan, the zoomed
//  folder and the selection, then agent instruction files and the files
//  with the most tokens. Rows select like the other statistics lists.
//

import SwiftUI
import NeodiskKit

struct TokensPane: View {
    let model: NeodiskViewModel

    private static let listLimit = 100
    private static let limitChoices = [2_000, 5_000, 10_000, 20_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.tokens.phase {
            case .ready:
                summary
                Divider()
                fileList
            case .counting(let done, let total):
                VStack(alignment: .leading, spacing: 6) {
                    StripedProgressBar(value: total > 0 ? Double(done) / Double(total) : 0)
                    Text(String(
                        format: NSLocalizedString("Counting tokens… %@ of %@ files", comment: "Token mode progress"),
                        done.formatted(), total.formatted()
                    ))
                    .neoFont(11)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                Spacer()
            case .idle, .waitingForScan:
                StatsEmptyState(
                    symbol: "text.word.spacing",
                    message: Text("Tokens are counted when the scan finishes")
                )
            }
            Divider()
            Text("Estimated tokens. Exact counts vary by model.")
                .neoFont(10)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
    }

    // MARK: Summary

    private var summary: some View {
        let tokens = model.tokens
        let total = tokens.tokenStore?.root.allocatedSize ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            TokenSummaryRow(
                title: "Whole scan",
                value: DisplayFormatters.tokens(Int(total)),
                detail: String(
                    format: NSLocalizedString("%@ text files · %@ not text", comment: "Token totals, file counts"),
                    (tokens.tally?.textFileCount ?? 0).formatted(),
                    (tokens.tally?.nonTextFileCount ?? 0).formatted()
                )
            )
            if let folder = zoomedFolder {
                TokenSummaryRow(
                    title: LocalizedStringKey(folder.name),
                    value: DisplayFormatters.tokens(tokens.tokens(for: folder.id) ?? 0),
                    detail: shareText(of: folder.id, total: total)
                )
            }
            if let node = model.selectedNode, node.id != model.effectiveRootID {
                TokenSummaryRow(
                    title: LocalizedStringKey(node.name),
                    value: tokens.tokens(for: node.id).map(DisplayFormatters.tokens)
                        ?? NSLocalizedString("Not counted", comment: "Token mode, a file without a token count"),
                    detail: selectionDetail(node, total: total),
                    isFlagged: isFlagged(node.id)
                )
            }
        }
        .padding(10)
    }

    private var zoomedFolder: FileNodeRecord? {
        guard let id = model.zoomRootID, id != model.store?.rootID else { return nil }
        return model.store?.node(id: id)
    }

    private func shareText(of nodeID: String, total: Int64) -> String? {
        guard let tokens = model.tokens.tokens(for: nodeID),
              let percent = NeodiskFormatters.percentage(part: Int64(tokens), total: total) else { return nil }
        return String(format: NSLocalizedString("%@ of the scan", comment: "Token share of the whole scan"), percent)
    }

    private func selectionDetail(_ node: FileNodeRecord, total: Int64) -> String? {
        if isFlagged(node.id) {
            return NSLocalizedString("Above the agent file limit", comment: "Token mode, oversized agent instruction file")
        }
        if model.tokens.isSampled(node.id) {
            return NSLocalizedString("Estimated from the first 4 MB", comment: "Token mode, very large file")
        }
        return shareText(of: node.id, total: total)
    }

    private func isFlagged(_ nodeID: String) -> Bool {
        guard let tokens = model.tokens.tally?.tokensByID[nodeID],
              tokens > model.agentFileTokenLimit,
              let node = model.store?.node(id: nodeID) else { return false }
        return AgentInstructionFiles.matches(node)
    }

    // MARK: Lists

    private var fileList: some View {
        let selection = Binding<String?>(
            get: { model.selectedNodeID },
            set: { if let id = $0 { model.select(id) } }
        )
        let agentIDs = model.tokens.agentFileIDs
        let topIDs = model.tokens.topFileIDs(in: model.effectiveRootID, limit: Self.listLimit)
        return List(selection: selection) {
            if !agentIDs.isEmpty {
                Section {
                    ForEach(agentIDs.prefix(Self.listLimit), id: \.self, content: row)
                } header: {
                    agentHeader
                }
            }
            Section {
                ForEach(topIDs, id: \.self, content: row)
            } header: {
                Text(zoomedFolder.map {
                    String(format: NSLocalizedString("Most tokens in %@", comment: "Token list header, zoomed folder"), $0.name)
                } ?? NSLocalizedString("Most tokens", comment: "Token list header"))
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .fileNodeActions(model: model)
        .environment(\.defaultMinListRowHeight, 20)
        .quickLookOnSpace(model: model)
    }

    @ViewBuilder
    private func row(_ nodeID: String) -> some View {
        if let node = model.store?.node(id: nodeID) {
            TokenFileRow(
                node: node,
                tokens: model.tokens.tally?.tokensByID[nodeID] ?? 0,
                isFlagged: isFlagged(nodeID),
                palette: model.vizPalette
            )
            .listRowSeparator(.hidden)
        }
    }

    private static func limitTitle(_ limit: Int) -> String {
        String(
            format: NSLocalizedString("Flag above %@", comment: "Agent file token limit menu"),
            limit.formatted(.number.notation(.compactName))
        )
    }

    private var agentHeader: some View {
        @Bindable var tokens = model.tokens
        return HStack(spacing: 6) {
            Text("Agent files")
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Menu {
                ForEach(Self.limitChoices, id: \.self) { limit in
                    Button {
                        model.preferences?.agentFileTokenLimit = limit
                    } label: {
                        if limit == model.agentFileTokenLimit {
                            Label(Self.limitTitle(limit), systemImage: "checkmark")
                        } else {
                            Text(Self.limitTitle(limit))
                        }
                    }
                }
            } label: {
                Label(
                    model.agentFileTokenLimit.formatted(.number.notation(.compactName)),
                    systemImage: "exclamationmark.triangle"
                )
                .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Flag agent instruction files above this many tokens")
            Toggle(isOn: $tokens.highlightsAgentFiles) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Highlight agent files on the map")
        }
    }
}

private struct TokenSummaryRow: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    var isFlagged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .neoFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value)
                    .neoFont(12, weight: .medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if let detail {
                HStack(spacing: 4) {
                    if isFlagged {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(detail)
                        .foregroundStyle(isFlagged ? .orange : .secondary)
                }
                .neoFont(10)
                .lineLimit(1)
            }
        }
    }
}

/// File row with its token count; oversized agent files wear a warning.
private struct TokenFileRow: View {
    let node: FileNodeRecord
    let tokens: Int
    let isFlagged: Bool
    let palette: VizPalette

    var body: some View {
        HStack(spacing: 6) {
            FileCategoryIcon(node: node, palette: palette)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(containingFolder)
                    .foregroundStyle(.secondary)
                    .neoFont(10)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if isFlagged {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .neoFont(10)
                    .help("Above the agent file limit")
            }
            Text(DisplayFormatters.tokenCount(tokens))
                .foregroundStyle(isFlagged ? .orange : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .neoFont(12)
        .help(DisplayFormatters.displayPath(node.path))
    }

    private var containingFolder: String {
        (DisplayFormatters.displayPath(node.path) as NSString).deletingLastPathComponent
    }
}
