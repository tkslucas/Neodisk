//
//  KindStatsPane.swift
//  Neodisk
//
//  The statistics panel's Kinds tab: one row per file kind with its treemap
//  color, total size, and file count, largest first.
//

import SwiftUI
import NeodiskKit

struct KindStatsPane: View {
    let model: NeodiskViewModel

    var body: some View {
        if model.kinds.drill.isActive {
            @Bindable var drill = model.kinds.drill
            StatsFileListView(
                model: model,
                title: model.kinds.drill.context?.kind.displayName,
                swatch: model.kinds.drill.context.map { context in
                    Color(rgb: model.kinds.catalog.rgb(forKindID: context.kind.id))
                },
                backHelp: "Back to file kinds",
                isLoading: model.kinds.drill.isLoading,
                visibleIDs: model.kinds.drill.visibleIDs,
                totalMatches: model.kinds.drill.totalMatches,
                filterText: $drill.filterText,
                onClose: { model.kinds.closeFileList() }
            )
        } else {
            kindStatsList
        }
    }

    private var kindStatsList: some View {
        @Bindable var kinds = model.kinds
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Group by")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $kinds.displayMode) {
                    ForEach(FileKindDisplayMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider()

            if model.kinds.catalog.stats.isEmpty || model.kinds.catalog.mode != model.kinds.displayMode {
                // Either nothing built yet, or the user just switched modes
                // and the catalog for the new mode is still building — don't
                // show the stale list.
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.kinds.catalog.stats) { stat in
                    StatsLegendRow(
                        swatch: stat.color,
                        name: LocalizedStringKey(stat.kind.displayName),
                        fileCount: stat.fileCount,
                        totalAllocatedSize: stat.totalAllocatedSize,
                        totalSize: totalSize
                    )
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.kinds.openFileList(for: stat)
                    }
                    .help("Show every file of this kind")
                }
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private var totalSize: Int64 {
        model.coordinator.snapshot?.aggregateStats.totalAllocatedSize ?? 0
    }
}
