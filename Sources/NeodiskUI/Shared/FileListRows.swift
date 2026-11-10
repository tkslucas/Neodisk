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
    /// Read in the body, so the row dims the moment its item joins or leaves Cleanup.
    var cleanup: CleanupModel? = nil

    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        let cleanupMark = cleanup?.mark(for: node.id) ?? .none
        let onAccent = backgroundProminence == .increased
        HStack(spacing: 6) {
            FileCategoryIcon(node: node, palette: palette)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if cleanupMark.isItem {
                        CleanupRowGlyph(onAccent: onAccent)
                    }
                }
                Text(containingFolder)
                    .foregroundStyle(.secondary)
                    .neoFont(10)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // Ahead of the spacer, or the HStack splits the leftover width between them and names truncate early;
            // the stack's spacing on both sides of it is gap enough.
            .layoutPriority(1)
            .neoHelp(node.path)

            Spacer(minLength: 0)

            FileSizeLabel(node: node, includeCloudOnly: includeCloudOnly)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let cleanup {
                CleanupRowButton(node: node, cleanup: cleanup, onAccent: onAccent)
            }
        }
        .neoFont(12)
        .cleanupDimmed(cleanupMark.isMarked, onAccent: onAccent)
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
    /// The text it sits beside, which it scales with.
    var fontSize: CGFloat = 11

    /// Its slot's width at 100%.
    static func size(fontSize: CGFloat) -> CGFloat { fontSize + 5 }

    var body: some View {
        Image(systemName: FileKindClassifier.categorySymbol(forID: categoryID))
            .neoFont(fontSize, weight: .medium)
            .foregroundStyle(iconColor)
            .frame(width: (Self.size(fontSize: fontSize) * textScale).rounded())
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
