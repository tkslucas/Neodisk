//
//  StatsLegendRow.swift
//  Neodisk
//
//  One legend/stats row shared by the Kinds and Age tabs: a color swatch, the
//  name with a file count, and the size with its share of the total. Tapping
//  a row is wired up by each pane (it drills into that kind's / bucket's
//  files).
//

import SwiftUI
import NeodiskKit

struct StatsLegendRow: View {
    let swatch: Color
    let name: LocalizedStringKey
    let fileCount: Int
    let totalAllocatedSize: Int64
    let totalSize: Int64

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatch)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(fileCount.formatted()) files")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(NeodiskFormatters.size(totalAllocatedSize))
                    .monospacedDigit()
                if let percent = NeodiskFormatters.percentage(
                    part: totalAllocatedSize, total: totalSize
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
