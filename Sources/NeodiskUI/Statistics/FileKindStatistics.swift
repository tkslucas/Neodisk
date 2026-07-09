//
//  FileKindStatistics.swift
//  Neodisk
//
//  Groups scanned files by kind and assigns each kind a stable display color,
//  Disk Inventory X-style: the biggest kinds get distinct palette colors, the
//  long tail shares a neutral gray.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import NeodiskKit

struct FileKind: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

/// How the kind statistics group files: one row per extension, or a handful
/// of broad categories (Videos, Images, Apps, …).
enum FileKindDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case categories
    case types

    var id: String { rawValue }

    var title: String {
        switch self {
        case .categories: return "Categories"
        case .types: return "Types"
        }
    }
}

struct FileKindStat: Identifiable, Sendable {
    let kind: FileKind
    let totalAllocatedSize: Int64
    let fileCount: Int
    let rgb: SIMD3<Float>

    var id: String { kind.id }

    var color: Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

struct FileKindCatalog: Sendable {
    static let coloredKindLimit = 14

    /// Distinct saturated hues, ordered so the largest kinds get the most
    /// recognizable colors. Loosely mirrors the Disk Inventory X palette.
    nonisolated static let palette: [SIMD3<Float>] = [
        SIMD3(0.31, 0.48, 0.95), // blue
        SIMD3(0.90, 0.28, 0.26), // red
        SIMD3(0.30, 0.75, 0.32), // green
        SIMD3(0.83, 0.29, 0.83), // magenta
        SIMD3(0.95, 0.78, 0.20), // yellow
        SIMD3(0.25, 0.78, 0.82), // cyan
        SIMD3(0.95, 0.52, 0.19), // orange
        SIMD3(0.56, 0.36, 0.90), // purple
        SIMD3(0.20, 0.60, 0.50), // teal
        SIMD3(0.94, 0.45, 0.65), // pink
        SIMD3(0.62, 0.80, 0.24), // lime
        SIMD3(0.62, 0.44, 0.28), // brown
        SIMD3(0.42, 0.56, 0.14), // olive
        SIMD3(0.55, 0.27, 0.42), // plum
    ]

    nonisolated static let otherRGB = SIMD3<Float>(0.52, 0.52, 0.55)
    nonisolated static let directoryRGB = SIMD3<Float>(0.33, 0.33, 0.36)

    /// Categories keep fixed, meaningful colors regardless of size rank —
    /// videos are always blue, images always green, and so on. (Types keep
    /// rank-based colors: the biggest type gets the most prominent hue.)
    nonisolated static let categoryRGB: [String: SIMD3<Float>] = [
        "cat-video": SIMD3(0.31, 0.48, 0.95),      // blue
        "cat-image": SIMD3(0.30, 0.75, 0.32),      // green
        "cat-audio": SIMD3(0.25, 0.78, 0.82),      // cyan
        "cat-docs": SIMD3(0.95, 0.78, 0.20),       // yellow
        "cat-archive": SIMD3(0.95, 0.52, 0.19),    // orange
        "cat-code": SIMD3(0.83, 0.29, 0.83),       // magenta
        "cat-data": SIMD3(0.56, 0.36, 0.90),       // purple
        "cat-apps": SIMD3(0.90, 0.28, 0.26),       // red
        "cat-summarized": SIMD3(0.20, 0.60, 0.50), // teal
        "cat-system": SIMD3(0.62, 0.44, 0.28),     // brown
        "cat-other": otherRGB,
    ]

    static var otherColor: Color {
        Color(red: Double(otherRGB.x), green: Double(otherRGB.y), blue: Double(otherRGB.z))
    }

    let stats: [FileKindStat]
    let mode: FileKindDisplayMode
    /// Distinguishes catalog builds cheaply; every rebuild may reassign
    /// palette colors even when the kind count is unchanged.
    let buildID = UUID()
    private let rgbByKindID: [String: SIMD3<Float>]

    nonisolated init(stats: [FileKindStat], mode: FileKindDisplayMode = .types) {
        self.stats = stats
        self.mode = mode
        var mapping: [String: SIMD3<Float>] = [:]
        mapping.reserveCapacity(stats.count)
        for stat in stats {
            mapping[stat.kind.id] = stat.rgb
        }
        rgbByKindID = mapping
    }

    nonisolated static let empty = FileKindCatalog(stats: [])

    nonisolated func rgb(forKindID kindID: String) -> SIMD3<Float> {
        rgbByKindID[kindID] ?? Self.otherRGB
    }

    nonisolated func rgb(for node: FileNodeRecord) -> SIMD3<Float> {
        if node.isDirectory, !FileKindClassifier.isKindCountable(node) {
            return Self.directoryRGB
        }
        return rgb(forKindID: FileKindClassifier.kindID(for: node, mode: mode))
    }

    func color(for node: FileNodeRecord) -> Color {
        let rgb = rgb(for: node)
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// Builds kind statistics for every countable node in the tree — files
    /// plus leaf-like directories (packages such as .app bundles, and
    /// auto-summarized folders) — sorted by total size, with palette colors
    /// assigned to the largest kinds.
    ///
    /// The per-node loop deals only in cheap kind-ID strings; display names
    /// (which can hit Launch Services for type descriptions) resolve once
    /// per unique kind afterwards, through a cache shared across builds.
    nonisolated static func build(
        from store: FileTreeStore,
        mode: FileKindDisplayMode = .types,
        palette: VizPalette = .standard
    ) -> FileKindCatalog {
        var sizeByKindID: [String: (size: Int64, count: Int)] = [:]

        for node in store.allNodes {
            guard FileKindClassifier.isKindCountable(node) else { continue }
            let kindID = FileKindClassifier.kindID(for: node, mode: mode)
            let existing = sizeByKindID[kindID] ?? (0, 0)
            sizeByKindID[kindID] = (existing.size + node.allocatedSize, existing.count + 1)
        }

        return build(
            fromAggregated: sizeByKindID.map {
                PersistedKindStat(kindID: $0.key, size: $0.value.size, count: $0.value.count)
            },
            mode: mode,
            palette: palette
        )
    }

    /// Ranking, palette assignment, and display-name resolution from
    /// per-kind aggregates — the tail of `build(from:)`, split out so a
    /// catalog can also rebuild from persisted aggregates (snapshot restore,
    /// palette or grouping-mode switches) without an O(nodes) pass.
    nonisolated static func build(
        fromAggregated aggregated: [PersistedKindStat],
        mode: FileKindDisplayMode,
        palette: VizPalette = .standard
    ) -> FileKindCatalog {
        let ranked = aggregated.sorted {
            if $0.size != $1.size {
                return $0.size > $1.size
            }
            return $0.kindID < $1.kindID
        }

        let stats = ranked.enumerated().map { index, entry in
            let rgb: SIMD3<Float>
            switch mode {
            case .categories:
                rgb = palette.categoryRGB[entry.kindID] ?? otherRGB
            case .types:
                rgb = index < palette.kindPalette.count ? palette.kindPalette[index] : otherRGB
            }
            return FileKindStat(
                kind: FileKindClassifier.kind(forID: entry.kindID, mode: mode),
                totalAllocatedSize: entry.size,
                fileCount: entry.count,
                rgb: rgb
            )
        }

        return FileKindCatalog(stats: stats, mode: mode)
    }

    /// The catalog's aggregates in persistable form (colors and display
    /// names are derived, so they are not stored).
    var persistedStats: [PersistedKindStat] {
        stats.map {
            PersistedKindStat(
                kindID: $0.kind.id,
                size: $0.totalAllocatedSize,
                count: $0.fileCount
            )
        }
    }

    /// Both grouping modes aggregated in a single pass over the tree — the
    /// save-time producer of the persisted stats a restore rebuilds from.
    nonisolated static func aggregateBothModes(
        from store: FileTreeStore
    ) -> (categories: [PersistedKindStat], types: [PersistedKindStat]) {
        var categorySizes: [String: (size: Int64, count: Int)] = [:]
        var typeSizes: [String: (size: Int64, count: Int)] = [:]

        for node in store.allNodes {
            guard FileKindClassifier.isKindCountable(node) else { continue }
            let categoryID = FileKindClassifier.kindID(for: node, mode: .categories)
            let typeID = FileKindClassifier.kindID(for: node, mode: .types)
            categorySizes[categoryID, default: (0, 0)].size += node.allocatedSize
            categorySizes[categoryID, default: (0, 0)].count += 1
            typeSizes[typeID, default: (0, 0)].size += node.allocatedSize
            typeSizes[typeID, default: (0, 0)].count += 1
        }

        func persisted(_ sizes: [String: (size: Int64, count: Int)]) -> [PersistedKindStat] {
            sizes.map { PersistedKindStat(kindID: $0.key, size: $0.value.size, count: $0.value.count) }
        }
        return (persisted(categorySizes), persisted(typeSizes))
    }
}

/// One kind's persisted aggregate — enough to rebuild a FileKindCatalog
/// without touching the tree.
nonisolated struct PersistedKindStat: Codable, Sendable {
    let kindID: String
    let size: Int64
    let count: Int
}
