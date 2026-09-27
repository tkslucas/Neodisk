//
//  VolumeCapacitySegments.swift
//  NeodiskAppModel
//
//  The segments of a sidebar volume's capacity bar, storage-settings style:
//  one per file kind category (the Kinds tab's colors), then a neutral tail
//  for used capacity the scan didn't account for. The empty track after
//  them stands for free space. Both apps draw their bar from this.
//

import Foundation
import NeodiskKit

package nonisolated struct VolumeCapacitySegment: Equatable, Sendable, Identifiable {
    package let id: String
    /// Localization key for the hover label: a kind category display name,
    /// or "Hidden Space" for the unscanned tail.
    package let label: String
    package let size: Int64
    package let rgb: SIMD3<Float>
    /// Fraction of the volume's total capacity.
    package let fraction: Double

    package init(id: String, label: String, size: Int64, rgb: SIMD3<Float>, fraction: Double) {
        self.id = id
        self.label = label
        self.size = size
        self.rgb = rgb
        self.fraction = fraction
    }
}

package nonisolated enum VolumeCapacitySegments {
    /// Segments for a scanned volume, largest category first; empty when
    /// the volume reports no capacity.
    package static func make(
        space: VolumeSpaceInfo?,
        sidecar: KindStatsSidecar,
        scannedBytes: Int64,
        palette: VizPalette
    ) -> [VolumeCapacitySegment] {
        guard let space, space.totalCapacity > 0 else { return [] }
        let total = space.totalCapacity

        var sizeByKindID: [String: Int64] = [:]
        for stat in sidecar.stats(for: .categories) where stat.size > 0 {
            sizeByKindID[stat.kindID, default: 0] += stat.size
        }
        // Scanned bytes the kind stats don't cover (directory overhead,
        // synthetic nodes) fold into the catch-all category, so the colored
        // segments tile the scanned tree exactly and the hidden tail below
        // states the same figure as the sunburst legend.
        let categorizedBytes = sizeByKindID.values.reduce(0, +)
        let uncategorized = scannedBytes - categorizedBytes
        if uncategorized > 0 {
            sizeByKindID["cat-other", default: 0] += uncategorized
        }

        var segments: [VolumeCapacitySegment] = sizeByKindID
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { kindID, size in
                VolumeCapacitySegment(
                    id: kindID,
                    label: FileKindClassifier.kind(forID: kindID, mode: .categories).displayName,
                    size: size,
                    rgb: palette.categoryRGB[kindID] ?? FileKindCatalog.otherRGB,
                    fraction: Double(size) / Double(total)
                )
            }

        // Used capacity the scan didn't account for (unreadable paths,
        // other users' homes, snapshot-held blocks): a neutral tail
        // segment, like macOS "System Data" — same formula everywhere.
        if let hidden = space.hiddenSpaceBytes(scannedBytes: max(scannedBytes, categorizedBytes)) {
            segments.append(VolumeCapacitySegment(
                id: "unscanned",
                label: "Hidden Space",
                size: hidden,
                rgb: FileKindCatalog.otherRGB,
                fraction: Double(hidden) / Double(total)
            ))
        }
        return segments
    }
}
