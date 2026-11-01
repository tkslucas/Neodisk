import SwiftUI
import NeodiskKit
import NeodiskAppModel

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
                    // Purgeable space counts as free, annotated so the figure matches the system "available"
                    // number.
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
            } else if model.hoveredNode == nil, model.selection.isMultiple, let summary = model.selectionSummary {
                Text(Self.countText(summary.count))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if summary.inCleanup > 0 {
                    Label(Self.inCleanupText(summary.inCleanup, of: summary.count), systemImage: "trash")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(NeodiskFormatters.size(summary.totalSize))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            } else if let node = model.hoveredNode ?? model.selectedNode {
                RoundedRectangle(cornerRadius: 2)
                    .fill(hoverOrSelectionSwatch(for: node))
                    .frame(width: 10, height: 10)
                Text(node.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if let cleanupText = model.cleanup.mark(for: node.id).hoverText {
                    Label(cleanupText, systemImage: "trash")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(LocalizedStringKey(FileKindClassifier.kind(for: node, mode: model.kinds.displayMode).displayName))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Self.sizeText(for: node))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            } else if let root = model.store?.root {
                // At rest, the whole scan: what's in it and what it weighs.
                Text(AppStrings.plural(
                    root.descendantFileCount, one: "%@ item", other: "%@ items", root.descendantFileCount.formatted()
                ))
                .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(Self.sizeText(for: root))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Spacer()
            }
        }
        // One line at any width or text size: the bar never takes height from the panes.
        .lineLimit(1)
        .neoFont(11)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    static func countText(_ count: Int) -> String {
        String(format: NSLocalizedString("%lld items selected", comment: "Status bar, several items selected"), count)
    }

    static func inCleanupText(_ inCleanup: Int, of count: Int) -> String {
        inCleanup == count
            ? NSLocalizedString("All in Cleanup", comment: "Status bar, every selected item is in Cleanup")
            : String(format: NSLocalizedString("%lld in Cleanup", comment: "Status bar, selected items in Cleanup"), inCleanup)
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

    /// A dataless file is ~0 on disk, so its logical size shows with a qualifier; a folder splits on-disk
    /// from cloud-only bytes.
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
