//
//  AgeStatistics.swift
//  Neodisk
//
//  Groups scanned files by how long ago they were modified and assigns each
//  age bucket a fixed ramp color (recent = cool, stale = hot), mirroring the
//  file-kind statistics: the buckets drive the treemap's age color mode and
//  the Age tab of the statistics panel.
//

import Foundation
import NeodiskKit

/// Discrete modification-age buckets, newest first. Boundaries are measured
/// against the snapshot's scan date, not "now", so a cached snapshot colors
/// identically to the day it was scanned and renders are reproducible.
package enum AgeBucket: Int, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case quarter
    case year
    case older
    /// The scanner couldn't read a modification date.
    case unknown

    package var id: Int { rawValue }

    package var displayName: String {
        switch self {
        case .day: return "Today"
        case .week: return "Past Week"
        case .month: return "Past Month"
        case .quarter: return "Past 3 Months"
        case .year: return "Past Year"
        case .older: return "Older"
        case .unknown: return "No Date"
        }
    }

    private nonisolated static let dayLength: TimeInterval = 86_400

    /// The bucket for a modification date relative to `reference` (the scan
    /// date). Future dates — clock skew, restored backups — count as today.
    package nonisolated static func bucket(for date: Date?, reference: Date) -> AgeBucket {
        guard let date else { return .unknown }
        let age = reference.timeIntervalSince(date)
        switch age {
        case ..<(dayLength * 1): return .day
        case ..<(dayLength * 7): return .week
        case ..<(dayLength * 30): return .month
        case ..<(dayLength * 91): return .quarter
        case ..<(dayLength * 365): return .year
        default: return .older
        }
    }
}

package struct AgeStat: Identifiable, Sendable {
    package let bucket: AgeBucket
    package let totalAllocatedSize: Int64
    package let fileCount: Int

    package var id: Int { bucket.rawValue }
}

/// Per-bucket totals over one snapshot, in bucket (chronological) order so
/// the legend reads as a timeline. Counts the same nodes as the kind
/// statistics: files, packages, and auto-summarized folders.
package struct AgeCatalog: Sendable {
    /// Non-empty buckets only, newest first.
    package let stats: [AgeStat]
    /// The scan date every bucket boundary is measured against.
    package let referenceDate: Date
    /// Distinguishes catalog builds cheaply, like FileKindCatalog.buildID.
    package let buildID = UUID()

    package nonisolated static let empty = AgeCatalog(stats: [], referenceDate: .distantPast)

    package nonisolated init(stats: [AgeStat], referenceDate: Date) {
        self.stats = stats
        self.referenceDate = referenceDate
    }

    package nonisolated static func build(from store: FileTreeStore, referenceDate: Date) -> AgeCatalog {
        var sizes = [Int64](repeating: 0, count: AgeBucket.allCases.count)
        var counts = [Int](repeating: 0, count: AgeBucket.allCases.count)

        for node in store.allNodes {
            if Task.isCancelled { break }
            guard FileKindClassifier.isKindCountable(node, in: store) else { continue }
            let bucket = AgeBucket.bucket(for: node.lastModified, reference: referenceDate)
            sizes[bucket.rawValue] += node.allocatedSize
            counts[bucket.rawValue] += 1
        }

        let stats = AgeBucket.allCases.compactMap { bucket -> AgeStat? in
            guard counts[bucket.rawValue] > 0 else { return nil }
            return AgeStat(
                bucket: bucket,
                totalAllocatedSize: sizes[bucket.rawValue],
                fileCount: counts[bucket.rawValue]
            )
        }
        return AgeCatalog(stats: stats, referenceDate: referenceDate)
    }
}
