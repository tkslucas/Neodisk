//
//  FileListRows.swift
//  Neodisk
//
//  Row views shared by the search results and the statistics drill-in file
//  lists: the name/size row and its kind icon.
//

import SwiftUI
import NeodiskKit

/// Search-result row shared by the outline's entire-scan results and the
/// statistics file lists: category icon tinted with the category's fixed
/// color (the treemap's Categories palette, so lists and map speak the same
/// color language), name, dimmed containing folder, size.
struct FileResultRow: View {
    let node: FileNodeRecord
    /// The active palette, so tints follow the colorblind Settings toggle.
    var palette: VizPalette = .standard

    var body: some View {
        HStack(spacing: 6) {
            FileCategoryIcon(node: node, palette: palette)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(containingFolder)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(NeodiskFormatters.size(node.allocatedSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12))
        .help(DisplayFormatters.displayPath(node.path))
    }

    private var containingFolder: String {
        (DisplayFormatters.displayPath(node.path) as NSString).deletingLastPathComponent
    }
}

/// Growth since the baseline scan: "+1.2 GB" in red, "−340 MB" in green,
/// a quiet dot for unchanged nodes. Shared by the outline's diff column and
/// the statistics panel's Changes tab, so every delta in the app speaks the
/// same color language.
struct DeltaLabel: View {
    let delta: Int64

    var body: some View {
        Group {
            if delta == 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
            } else if delta > 0 {
                Text("+\(NeodiskFormatters.size(delta))")
                    .foregroundStyle(.red)
            } else {
                Text("−\(NeodiskFormatters.size(-delta))")
                    .foregroundStyle(.green)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A node's category icon tinted with the category's fixed color — the
/// treemap's Categories palette, so the file lists and the map speak the
/// same color language.
struct FileCategoryIcon: View {
    let node: FileNodeRecord
    /// The active palette, so tints follow the colorblind Settings toggle.
    let palette: VizPalette

    var body: some View {
        Image(systemName: FileKindClassifier.categorySymbol(forID: categoryID))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 16)
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
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}
