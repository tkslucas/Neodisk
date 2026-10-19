// Row views shared by the search results and the statistics drill-in file
// lists: the name/size row and its kind icon.

import SwiftUI
import NeodiskKit
import NeodiskAppModel

/// With the cloud-only toggle on, cloud-backed nodes show the combined size plus a cloud glyph, matching the
/// map. The glyph slot stays (empty) on local rows so size digits right-align down a list.
struct FileSizeLabel: View {
    /// OutlineRowMetrics measures through this too, so both share one function rather than a literal.
    static func glyphSlotWidth(scale: CGFloat) -> CGFloat {
        (12 * scale).rounded()
    }

    @Environment(\.neoTextScale) private var textScale

    let node: FileNodeRecord
    let includeCloudOnly: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(NeodiskFormatters.size(node.displayWeight(includingCloudOnly: includeCloudOnly)))
            if includeCloudOnly {
                Image(systemName: "cloud.fill")
                    .neoFont(9, weight: .medium)
                    .opacity(node.cloudOnlyLogicalSize > 0 ? 1 : 0)
                    .frame(width: Self.glyphSlotWidth(scale: textScale))
            }
        }
    }
}

struct FileResultRow: View {
    let node: FileNodeRecord
    /// The active palette, so tints follow the colorblind Settings toggle.
    var palette: VizPalette = .standard
    var includeCloudOnly: Bool = false

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

            FileSizeLabel(node: node, includeCloudOnly: includeCloudOnly)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .neoFont(12)
        .help(node.path)
    }

    private var containingFolder: String {
        (node.path as NSString).deletingLastPathComponent
    }
}

/// Shared by the outline's diff column and the Changes tab so every delta uses the same colors.
struct DeltaLabel: View {
    let delta: Int64

    var body: some View {
        Group {
            // Text comes from the shared formatter so the outline's
            // width-measurement path can never drift from what renders.
            if delta == 0 {
                Text(NeodiskFormatters.sizeDelta(delta))
                    .foregroundStyle(.tertiary)
            } else if delta > 0 {
                Text(NeodiskFormatters.sizeDelta(delta))
                    .foregroundStyle(.red)
            } else {
                Text(NeodiskFormatters.sizeDelta(delta))
                    .foregroundStyle(.green)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The treemap's Categories palette, so the lists and the map use the same colors.
struct FileCategoryIcon: View {
    @Environment(\.neoTextScale) private var textScale

    let node: FileNodeRecord
    /// The active palette, so tints follow the colorblind Settings toggle.
    let palette: VizPalette

    var body: some View {
        Image(systemName: FileKindClassifier.categorySymbol(forID: categoryID))
            .neoFont(11, weight: .medium)
            .foregroundStyle(iconColor)
            .frame(width: (16 * textScale).rounded())
    }

    private var categoryID: String {
        FileKindClassifier.kindID(for: node, mode: .categories)
    }

    /// Folders share the neutral "other" grey — the directory treemap grey
    /// is tuned for cushion shading and all but vanishes as a glyph.
    private var iconColor: Color {
        let rgb = categoryID == "folder"
            ? FileKindCatalog.otherRGB
            : palette.categoryRGB[categoryID] ?? FileKindCatalog.otherRGB
        return Color(rgb: rgb)
    }
}
