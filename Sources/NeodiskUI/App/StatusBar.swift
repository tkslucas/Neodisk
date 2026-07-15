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
                    .fill(Color(
                        red: Double(SyntheticSpaceColors.freeSpaceRGB.x),
                        green: Double(SyntheticSpaceColors.freeSpaceRGB.y),
                        blue: Double(SyntheticSpaceColors.freeSpaceRGB.z)
                    ))
                    .frame(width: 10, height: 10)
                Text("Free space on this volume")
                Spacer(minLength: 12)
                if let freeSpaceBytes = model.freeSpace.freeSpaceBytes {
                    Text(NeodiskFormatters.size(freeSpaceBytes))
                        .monospacedDigit()
                }
            } else if model.hoveredCellIsHiddenSpace {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(
                        red: Double(SyntheticSpaceColors.hiddenSpaceRGB.x),
                        green: Double(SyntheticSpaceColors.hiddenSpaceRGB.y),
                        blue: Double(SyntheticSpaceColors.hiddenSpaceRGB.z)
                    ))
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
                    .fill(FileKindCatalog.otherColor)
                    .frame(width: 10, height: 10)
                Text("\(aggregate.itemCount.formatted()) smaller items in \(folder.url.path)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(NeodiskFormatters.size(aggregate.totalSize))
                    .monospacedDigit()
            } else if let node = model.hoveredNode ?? model.selectedNode {
                RoundedRectangle(cornerRadius: 2)
                    .fill(model.displayColor(for: node))
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
