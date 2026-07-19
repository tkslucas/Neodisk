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
        if model.ages.drill.isActive {
            @Bindable var drill = model.ages.drill
            StatsFileListView(
                model: model,
                title: model.ages.drill.context?.displayName,
                swatch: model.ages.drill.context.map { model.vizPalette.ageColor($0) },
                backHelp: "Back to age groups",
                isLoading: model.ages.drill.isLoading,
                visibleIDs: model.ages.drill.visibleIDs,
                totalMatches: model.ages.drill.totalMatches,
                filterText: $drill.filterText,
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
                    StatsLegendRow(
                        swatch: model.vizPalette.ageColor(stat.bucket),
                        name: LocalizedStringKey(stat.bucket.displayName),
                        fileCount: stat.fileCount,
                        totalAllocatedSize: stat.totalAllocatedSize,
                        totalSize: totalSize
                    )
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
