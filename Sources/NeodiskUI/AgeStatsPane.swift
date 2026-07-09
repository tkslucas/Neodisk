//
//  AgeStatsPane.swift
//  Neodisk
//
//  The statistics panel's Age tab: one row per modification-age bucket with
//  its heatmap ramp color, total size, and file count — the legend for the
//  treemap's age color mode. Tapping a row drills into the files modified in
//  that period and lights them up on the map.
//

import SwiftUI
import NeodiskKit

struct AgeStatsPane: View {
    let model: NeodiskViewModel

    var body: some View {
        content
            // Covers both ways the catalog goes stale while the tab is on
            // screen: switching to the tab (appear) and a new snapshot
            // landing (id). Building only from here keeps the O(N) catalog
            // off the critical path while the tab is hidden.
            .task(id: model.coordinator.snapshot?.id) {
                model.ages.loadIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.ages.fileList != nil || model.ages.isFileListLoading {
            @Bindable var ages = model.ages
            StatsFileListView(
                model: model,
                title: model.ages.fileList?.bucket.displayName,
                swatch: model.ages.fileList.map { model.vizPalette.ageColor($0.bucket) },
                backHelp: "Back to age groups",
                isLoading: model.ages.isFileListLoading,
                visibleIDs: model.ages.fileListVisibleIDs,
                totalMatches: model.ages.fileListTotalMatches,
                filterText: $ages.fileListFilterText,
                onClose: { model.ages.closeFileList() }
            )
        } else {
            ageStatsList
        }
    }

    private var ageStatsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Last Modified")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            if model.ages.catalog.stats.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.ages.catalog.stats) { stat in
                    AgeStatRow(stat: stat, totalSize: totalSize, palette: model.vizPalette)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.ages.openFileList(for: stat)
                        }
                        .help("Show every file modified in this period")
                }
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private var totalSize: Int64 {
        model.coordinator.snapshot?.aggregateStats.totalAllocatedSize ?? 0
    }
}

private struct AgeStatRow: View {
    let stat: AgeStat
    let totalSize: Int64
    let palette: VizPalette

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(palette.ageColor(stat.bucket))
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(stat.bucket.displayName))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(stat.fileCount.formatted()) files")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(NeodiskFormatters.size(stat.totalAllocatedSize))
                    .monospacedDigit()
                if let percent = NeodiskFormatters.percentage(
                    part: stat.totalAllocatedSize, total: totalSize
                ) {
                    Text(percent)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 12))
    }
}
