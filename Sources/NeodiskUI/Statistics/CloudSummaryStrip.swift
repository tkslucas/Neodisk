//
//  CloudSummaryStrip.swift
//  Neodisk
//
//  A compact footer under the statistics panel, shown only when the scan
//  contains cloud-only (dataless) bytes: how much of the scanned tree lives
//  on this Mac versus only in the cloud, with a proportion bar. Read-only
//  summary — no download/evict actions.
//

import SwiftUI
import NeodiskKit

struct CloudSummaryStrip: View {
    /// On-disk bytes of the scanned root.
    let onThisMac: Int64
    /// Bytes that live only in the cloud below the scanned root.
    let cloudOnly: Int64

    /// Same hue, different intensity: no color-only encoding to decode, so
    /// the bar needs no colorblind-palette handling and the labels carry the
    /// meaning regardless. The cloud-only segment additionally wears the
    /// same diagonal hatch as dataless tiles and arcs, so the bar speaks
    /// the visualizations' texture language.
    private var onThisMacColor: Color { .accentColor }
    private var cloudOnlyColor: Color { .accentColor.opacity(0.3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Cloud storage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(onThisMacColor)
                        .frame(width: width(onThisMac, of: geometry.size.width))
                    Capsule()
                        .fill(cloudOnlyColor)
                        .overlay(DatalessHatchOverlay().clipShape(Capsule()))
                        .frame(width: width(cloudOnly, of: geometry.size.width))
                }
            }
            .frame(height: 6)

            HStack(spacing: 0) {
                legend(color: onThisMacColor, label: "On this Mac", bytes: onThisMac)
                Spacer(minLength: 8)
                legend(color: cloudOnlyColor, isHatched: true, label: "Cloud-only", bytes: cloudOnly)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func legend(
        color: Color, isHatched: Bool = false, label: LocalizedStringKey, bytes: Int64
    ) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay {
                    if isHatched {
                        DatalessHatchOverlay()
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
            Text(NeodiskFormatters.size(bytes))
                .monospacedDigit()
        }
        .font(.system(size: 10))
    }

    private func width(_ part: Int64, of totalWidth: CGFloat) -> CGFloat {
        let total = Double(onThisMac) + Double(cloudOnly)
        guard total > 0 else { return 0 }
        return totalWidth * CGFloat(Double(part) / total)
    }
}

/// The dataless diagonal hatch as an overlay for plain SwiftUI views —
/// the same brush the sunburst draws its cloud-only arcs with, so every
/// surface strokes the identical texture.
private struct DatalessHatchOverlay: View {
    var body: some View {
        Canvas { context, size in
            SunburstDatalessHatch(size: size)
                .draw(over: Path(CGRect(origin: .zero, size: size)), in: context)
        }
    }
}
