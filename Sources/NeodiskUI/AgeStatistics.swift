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
import SwiftUI
import NeodiskKit

/// Discrete modification-age buckets, newest first. Boundaries are measured
/// against the snapshot's scan date, not "now", so a cached snapshot colors
/// identically to the day it was scanned and renders are reproducible.
enum AgeBucket: Int, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case quarter
    case year
    case older
    /// The scanner couldn't read a modification date.
    case unknown

    var id: Int { rawValue }

    /// The ramp runs cool → hot with age: stale files glow warm so the eye
    /// lands on cleanup candidates. Hues reuse the kind palette's values so
    /// both color modes feel like one app.
    nonisolated var rgb: SIMD3<Float> {
        switch self {
        case .day: return SIMD3(0.31, 0.48, 0.95)     // blue
        case .week: return SIMD3(0.25, 0.78, 0.82)    // cyan
        case .month: return SIMD3(0.62, 0.80, 0.24)   // lime
        case .quarter: return SIMD3(0.95, 0.78, 0.20) // yellow
        case .year: return SIMD3(0.95, 0.52, 0.19)    // orange
        case .older: return SIMD3(0.90, 0.28, 0.26)   // red
        case .unknown: return FileKindCatalog.otherRGB
        }
    }

    var color: Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    var displayName: String {
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
    nonisolated static func bucket(for date: Date?, reference: Date) -> AgeBucket {
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

struct AgeStat: Identifiable, Sendable {
    let bucket: AgeBucket
    let totalAllocatedSize: Int64
    let fileCount: Int

    var id: Int { bucket.rawValue }
}

/// Per-bucket totals over one snapshot, in bucket (chronological) order so
/// the legend reads as a timeline. Counts the same nodes as the kind
/// statistics: files, packages, and auto-summarized folders.
struct AgeCatalog: Sendable {
    /// Non-empty buckets only, newest first.
    let stats: [AgeStat]
    /// The scan date every bucket boundary is measured against.
    let referenceDate: Date
    /// Distinguishes catalog builds cheaply, like FileKindCatalog.buildID.
    let buildID = UUID()

    nonisolated static let empty = AgeCatalog(stats: [], referenceDate: .distantPast)

    nonisolated init(stats: [AgeStat], referenceDate: Date) {
        self.stats = stats
        self.referenceDate = referenceDate
    }

    nonisolated static func build(from store: FileTreeStore, referenceDate: Date) -> AgeCatalog {
        var sizes = [Int64](repeating: 0, count: AgeBucket.allCases.count)
        var counts = [Int](repeating: 0, count: AgeBucket.allCases.count)

        for node in store.allNodes {
            guard FileKindClassifier.isKindCountable(node) else { continue }
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

/// Modification-age statistics state: the bucket catalog (rebuilt per
/// snapshot with the same adaptive throttle as the kind catalog) and the
/// drill-in file list for one bucket. Owned by NeodiskViewModel as
/// `model.ages` — the Age tab's counterpart to KindStatsModel.
@MainActor
@Observable
final class AgeStatsModel {
    private(set) var catalog: AgeCatalog = .empty

    // MARK: Bucket file list

    /// A bucket the user drilled into from the Age tab: every countable
    /// node modified in that period, largest first.
    struct FileList: Sendable {
        let bucket: AgeBucket
        /// Sorted by allocated size descending.
        let entries: [FileSearchEntry]
    }

    private(set) var fileList: FileList?
    /// Bucket lit up on the treemap while a drill-in list is open, mirroring
    /// KindStatsModel.highlightedKindID: derived, so it clears with
    /// closeFileList (snapshot changes reset it).
    var highlightedBucket: AgeBucket? { fileList?.bucket }
    private(set) var isFileListLoading = false
    private(set) var fileListVisibleIDs: [String] = []
    private(set) var fileListTotalMatches = 0
    var fileListFilterText = "" {
        didSet {
            guard fileListFilterText != oldValue else { return }
            scheduleFileListFilter()
        }
    }

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let indexService: SearchIndexService
    @ObservationIgnored private var fileListBuildTask: Task<Void, Never>?
    @ObservationIgnored private let fileListFilterDebouncer = SearchDebouncer()
    @ObservationIgnored private var catalogBuildTask: Task<Void, Never>?
    @ObservationIgnored private var lastCatalogBuildTime: ContinuousClock.Instant?
    /// Same rebuild throttle as KindStatsModel while partials stream in.
    @ObservationIgnored private var catalogRebuildInterval: Duration = AgeStatsModel.catalogRebuildBaseInterval
    private static let catalogRebuildBaseInterval: Duration = .seconds(1.5)

    init(coordinator: ScanCoordinator, indexService: SearchIndexService) {
        self.coordinator = coordinator
        self.indexService = indexService
    }

    /// Clears the displayed catalog before a new scan or snapshot takes the
    /// screen (part of the model's per-scan state reset).
    func reset() {
        catalog = .empty
    }

    /// The displayed tree changed: rebuild the bucket totals — throttled
    /// while partial snapshots stream in; the final snapshot always rebuilds.
    func snapshotDidChange(_ snapshot: ScanSnapshot?) {
        // The drilled-in bucket list holds node IDs of the replaced tree.
        closeFileList()

        guard let snapshot else {
            catalogBuildTask?.cancel()
            catalog = .empty
            lastCatalogBuildTime = nil
            return
        }

        if !snapshot.isComplete,
           let lastCatalogBuildTime,
           ContinuousClock.now - lastCatalogBuildTime < catalogRebuildInterval {
            return
        }
        lastCatalogBuildTime = ContinuousClock.now
        rebuildCatalog(from: snapshot)
    }

    private func rebuildCatalog(from snapshot: ScanSnapshot) {
        catalogBuildTask?.cancel()
        let store = snapshot.treeStore
        let referenceDate = snapshot.finishedAt ?? snapshot.startedAt
        catalogBuildTask = Task { [weak self] in
            let buildStart = ContinuousClock.now
            let catalog = await Task.detached(priority: .userInitiated) {
                AgeCatalog.build(from: store, referenceDate: referenceDate)
            }.value
            let buildDuration = ContinuousClock.now - buildStart
            guard !Task.isCancelled, let self else { return }
            self.catalogRebuildInterval = max(Self.catalogRebuildBaseInterval, buildDuration * 10)
            self.catalog = catalog
        }
    }

    // MARK: - Drill-in file list

    /// Opens the drill-in list for a bucket row ("what did I touch this
    /// week"), a filter over the shared per-snapshot search index.
    func openFileList(for stat: AgeStat) {
        guard let snapshot = coordinator.snapshot else { return }
        let bucket = stat.bucket
        let referenceDate = catalog.referenceDate
        fileListFilterText = ""
        isFileListLoading = true
        fileListBuildTask?.cancel()
        fileListBuildTask = Task { [weak self, indexService] in
            let index = await indexService.index(for: snapshot)
            let entries = await Task.detached(priority: .userInitiated) {
                index.entries.filter {
                    $0.isKindCountable
                        && AgeBucket.bucket(for: $0.lastModified, reference: referenceDate) == bucket
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isFileListLoading = false
            self.fileList = FileList(bucket: bucket, entries: entries)
            self.fileListVisibleIDs = entries.prefix(KindStatsModel.fileBrowseLimit).map(\.id)
            self.fileListTotalMatches = entries.count
        }
    }

    func closeFileList() {
        fileListBuildTask?.cancel()
        fileListFilterDebouncer.cancel()
        fileList = nil
        isFileListLoading = false
        fileListFilterText = ""
        fileListVisibleIDs = []
        fileListTotalMatches = 0
    }

    private func scheduleFileListFilter() {
        fileListFilterDebouncer.cancel()
        guard let list = fileList else { return }
        let query = fileListFilterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            fileListVisibleIDs = list.entries.prefix(KindStatsModel.fileBrowseLimit).map(\.id)
            fileListTotalMatches = list.entries.count
            return
        }
        let limit = SearchModel.resultLimit
        fileListFilterDebouncer.schedule { [weak self] in
            let entries = list.entries
            let results = await Task.detached(priority: .userInitiated) {
                FuzzyMatcher.topMatches(query: query, entries: entries, limit: limit)
            }.value
            guard let self, !Task.isCancelled,
                  self.fileListFilterText.trimmingCharacters(in: .whitespaces) == query else {
                return
            }
            self.fileListVisibleIDs = results.ids
            self.fileListTotalMatches = results.totalMatches
        }
    }
}
