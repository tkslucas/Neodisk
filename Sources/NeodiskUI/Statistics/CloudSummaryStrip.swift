// Shown only when the scan has cloud-only bytes. Read-only: no download or evict actions.

import SwiftUI
import NeodiskKit

struct CloudSummaryStrip: View {
    @Environment(\.neoTextScale) private var textScale

    /// On-disk bytes of the scanned root.
    let onThisMac: Int64
    /// Bytes that live only in the cloud below the scanned root.
    let cloudOnly: Int64

    /// Same hue at different intensity, so no colorblind handling is needed; the cloud-only segment also
    /// wears the dataless hatch.
    private var onThisMacColor: Color { .accentColor }
    private var cloudOnlyColor: Color { .accentColor.opacity(0.3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "cloud.fill")
                    .neoFont(10)
                    .foregroundStyle(.secondary)
                Text("Cloud storage")
                    .neoFont(11, weight: .semibold)
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
            .frame(height: (6 * textScale).rounded())

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
                .frame(width: (8 * textScale).rounded(), height: (8 * textScale).rounded())
            Text(label)
                .foregroundStyle(.secondary)
            Text(NeodiskFormatters.size(bytes))
                .monospacedDigit()
        }
        .neoFont(10)
    }

    private func width(_ part: Int64, of totalWidth: CGFloat) -> CGFloat {
        let total = Double(onThisMac) + Double(cloudOnly)
        guard total > 0 else { return 0 }
        return totalWidth * CGFloat(Double(part) / total)
    }
}
