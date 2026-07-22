//
//  StatusBar.swift
//  Neodisk
//
//  The bottom status bar: a swatch plus name/kind/size for whatever the user
//  is hovering or has selected — free space, hidden space, an aggregated
//  "smaller items" cell, or a real node — falling back to a hint when nothing
//  is under inspection.
//

import SwiftUI
import NeodiskKit

struct StatusBar: View {
    let model: NeodiskViewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.hoveredCellIsFreeSpace {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(rgb: model.visualizationHover?.swatchRGB ?? SyntheticSpaceColors.freeSpaceRGB))
                    .frame(width: 10, height: 10)
                Text("Free space on this volume")
                Spacer(minLength: 12)
                if let freeSpaceBytes = model.freeSpace.freeSpaceBytes {
                    // Finder-style available figure: purgeable space counts
                    // as free, annotated so the number still matches Disk
                    // Utility's "available" at a glance.
                    Text(Self.freeSpaceText(
                        freeSpaceBytes: freeSpaceBytes,
                        purgeableBytes: model.freeSpace.purgeableBytes
                    ))
                    .monospacedDigit()
                }
            } else if model.hoveredCellIsHiddenSpace {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(rgb: model.visualizationHover?.swatchRGB ?? SyntheticSpaceColors.hiddenSpaceRGB))
                    .frame(width: 10, height: 10)
                Text("Hidden space on this volume")
                    .help("Purgeable space, local snapshots, and files the scan could not see.")
                Spacer(minLength: 12)
                if let hiddenSpaceBytes = model.freeSpace.hiddenSpaceBytes {
                    Text(NeodiskFormatters.size(hiddenSpaceBytes))
                        .monospacedDigit()
                }
            } else if let aggregate = model.hoveredAggregate, let folder = model.hoveredNode {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(rgb: model.visualizationHover?.swatchRGB ?? FileKindCatalog.otherRGB))
                    .frame(width: 10, height: 10)
                Text("\(aggregate.itemCount.formatted()) smaller items in \(folder.url.path)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(NeodiskFormatters.size(aggregate.totalSize))
                    .monospacedDigit()
            } else if let node = model.hoveredNode ?? model.selectedNode {
                RoundedRectangle(cornerRadius: 2)
                    .fill(hoverOrSelectionSwatch(for: node))
                    .frame(width: 10, height: 10)
                Text(node.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(LocalizedStringKey(FileKindClassifier.kind(for: node, mode: model.kinds.displayMode).displayName))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Self.sizeText(for: node))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("Hover the treemap or select a row to inspect an item.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func hoverOrSelectionSwatch(for node: FileNodeRecord) -> Color {
        if case .node(let id, let rgb) = model.visualizationHover, id == node.id {
            return Color(rgb: rgb)
        }
        return model.displayColor(for: node)
    }

    /// The free-space figure with its purgeable share spelled out, so the
    /// number visibly matches what Finder and Disk Utility call available.
    static func freeSpaceText(freeSpaceBytes: Int64, purgeableBytes: Int64?) -> String {
        guard let purgeableBytes, purgeableBytes > 0 else {
            return NeodiskFormatters.size(freeSpaceBytes)
        }
        return String(
            format: NSLocalizedString("%@ (%@ purgeable)", comment: "Status bar free-space size with purgeable share"),
            NeodiskFormatters.size(freeSpaceBytes),
            NeodiskFormatters.size(purgeableBytes)
        )
    }

    /// Size for the inspected item, annotated when it carries cloud-only
    /// (not-downloaded) bytes: a dataless file is ~0 on disk, so its full
    /// logical size is shown with a qualifier; a folder splits its on-disk
    /// bytes from the cloud-only bytes below it.
    private static func sizeText(for node: FileNodeRecord) -> String {
        if node.isDataless {
            return String(
                format: NSLocalizedString("%@ · Cloud-only", comment: "Status bar size for a cloud-only file"),
                NeodiskFormatters.size(node.logicalSize)
            )
        }
        if node.isDirectory && node.cloudOnlyLogicalSize > 0 {
            return String(
                format: NSLocalizedString("%@ on this Mac · %@ cloud-only", comment: "Status bar size for a folder with cloud-only content"),
                NeodiskFormatters.size(node.allocatedSize),
                NeodiskFormatters.size(node.cloudOnlyLogicalSize)
            )
        }
        return NeodiskFormatters.size(node.allocatedSize)
    }
}
