//
//  KindStatsPane.swift
//  Neodisk
//
//  The statistics panel's Kinds tab, Disk Inventory X-style: one row per
//  file kind with its treemap color, total size, and file count, largest
//  first.
//

import SwiftUI
import NeodiskKit

struct KindStatsPane: View {
    let model: NeodiskViewModel

    var body: some View {
        if model.kinds.fileList != nil || model.kinds.isFileListLoading {
            @Bindable var kinds = model.kinds
            StatsFileListView(
                model: model,
                title: model.kinds.fileList?.kind.displayName,
                swatch: model.kinds.fileList.map { list in
                    let rgb = model.kinds.catalog.rgb(forKindID: list.kind.id)
                    return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
                },
                backHelp: "Back to file kinds",
                isLoading: model.kinds.isFileListLoading,
                visibleIDs: model.kinds.fileListVisibleIDs,
                totalMatches: model.kinds.fileListTotalMatches,
                filterText: $kinds.fileListFilterText,
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
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

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
                    KindStatRow(stat: stat, totalSize: totalSize)
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

private struct KindStatRow: View {
    let stat: FileKindStat
    let totalSize: Int64

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(stat.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(stat.kind.displayName))
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
