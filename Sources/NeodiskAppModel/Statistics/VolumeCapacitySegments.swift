//
//  VolumeCapacitySegments.swift
//  NeodiskAppModel
//
//  The segments of a sidebar volume's capacity bar, storage-settings style:
//  one per file kind category (the Kinds tab's colors), then a neutral tail
//  for used capacity the scan didn't account for. The empty track after
//  them stands for free space. A scanned folder's bar is its categories
//  alone, filling the bar. Both apps draw their bars from this.
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
        let sizes = categorySizes(sidecar: sidecar, scannedBytes: scannedBytes)
        let categorizedBytes = sizes.reduce(0) { $0 + $1.size }
        // A scan that counts more than the volume uses (blocks shared in a
        // way it can't see) would push the free track off the bar: the
        // categories then share the used space in proportion.
        let scale = categorizedBytes > space.usedBytes
            ? Double(space.usedBytes) / Double(categorizedBytes)
            : 1
        var segments = segments(sizes, palette: palette) { Double($0) * scale / Double(space.totalCapacity) }

        // Used capacity the scan didn't account for (unreadable paths,
        // other users' homes, snapshot-held blocks): a neutral tail
        // segment, like macOS "System Data" — same formula everywhere.
        if let hidden = space.hiddenSpaceBytes(scannedBytes: max(scannedBytes, categorizedBytes)) {
            segments.append(VolumeCapacitySegment(
                id: "unscanned",
                label: "Hidden Space",
                size: hidden,
                rgb: FileKindCatalog.otherRGB,
                fraction: Double(hidden) / Double(space.totalCapacity)
            ))
        }
        return segments
    }

    /// Segments for a scanned folder: its categories filling the whole bar,
    /// with no free track (a folder has no capacity of its own).
    package static func composition(
        sidecar: KindStatsSidecar,
        scannedBytes: Int64,
        palette: VizPalette
    ) -> [VolumeCapacitySegment] {
        let sizes = categorySizes(sidecar: sidecar, scannedBytes: scannedBytes)
        let total = sizes.reduce(0) { $0 + $1.size }
        guard total > 0 else { return [] }
        return segments(sizes, palette: palette) { Double($0) / Double(total) }
    }

    /// Bytes per category, largest first. Scanned bytes the kind stats don't
    /// cover (directory overhead, synthetic nodes) fold into the catch-all
    /// category, so the colored segments tile the scanned tree exactly and
    /// the hidden tail states the same figure as the sunburst legend.
    private static func categorySizes(sidecar: KindStatsSidecar, scannedBytes: Int64) -> [(kindID: String, size: Int64)] {
        var sizeByKindID: [String: Int64] = [:]
        for stat in sidecar.stats(for: .categories) where stat.size > 0 {
            sizeByKindID[stat.kindID, default: 0] += stat.size
        }
        let uncategorized = scannedBytes - sizeByKindID.values.reduce(0, +)
        if uncategorized > 0 {
            sizeByKindID["cat-other", default: 0] += uncategorized
        }
        return sizeByKindID
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { (kindID: $0.key, size: $0.value) }
    }

    private static func segments(
        _ sizes: [(kindID: String, size: Int64)],
        palette: VizPalette,
        fraction: (Int64) -> Double
    ) -> [VolumeCapacitySegment] {
        let rules = FileCategoryRules.current
        return sizes.map { kindID, size in
            VolumeCapacitySegment(
                id: kindID,
                label: FileKindClassifier.kind(forID: kindID, mode: .categories).displayName,
                size: size,
                rgb: palette.categoryRGB(forID: kindID, rules: rules),
                fraction: fraction(size)
            )
        }
    }
}
