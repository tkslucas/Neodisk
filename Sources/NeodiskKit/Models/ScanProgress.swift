//
//  ScanProgress.swift
//  Neodisk
//

import Foundation

/// Live scan progress. The public surface is what consumers display
/// (visit counts, bytes, current path, the blended progress fraction);
/// the traversal-accounting inputs that derive it stay internal to the
/// engine.
public struct ScanMetrics: Sendable {
    public init() {}

    public var filesVisited = 0
    public var directoriesVisited = 0
    public var bytesDiscovered: Int64 = 0
    public var currentPath = ""
    var discoveredItems = 0
    var completedItems = 0
    var estimatedTotalBytes: Int64 = 0
    /// Fraction of the tree's total traversal weight that has finished scanning (0...1).
    /// The scanner assigns the root a weight of 1 and recursively splits each directory's
    /// weight among its children when the directory is enumerated, so the sum of completed
    /// weights converges to 1 exactly as the traversal finishes.
    var completedTraversalWeight = 0.0
    /// Progress through the bottom-up assembly phase (0...1). Only meaningful while
    /// `isFinalizing` is true.
    var finalizationFraction = 0.0
    /// Directories whose contents have been enumerated (successfully or not).
    var enumeratedDirectoryCount = 0
    /// Directories discovered but not yet enumerated — the traversal frontier.
    var pendingDirectoryCount = 0
    /// Traversable directories counted in the active scan frontier for progress extrapolation.
    /// Final folder totals come from `ScanAggregateStats.directoryCount`, not this value.
    var discoveredDirectoryCount = 0
    public var progressFraction = 0.0
    public var isFinalizing = false
    /// True while an incremental rescan is rebuilding and splicing replacement
    /// subtrees into the retained baseline.
    public var isMergingChanges = false
    /// True while an incremental rescan is still deciding what to scan —
    /// decoding the baseline snapshot and replaying the FSEvents journal.
    /// No counters move during this phase, so the strip needs the flag to
    /// show activity instead of a dead bar.
    public var isCheckingChanges = false
    /// True once an attempted incremental rescan has degraded to a full scan
    /// (dropped events, an invalid checkpoint, a splice conflict, …). The
    /// strip surfaces this so a refresh that silently restarts from scratch is
    /// honest about it instead of looking like a mysterious long rescan. The
    /// root-relist path is a normal incremental rescan and never sets it.
    public var isFullScanFallback = false

    /// Portion of the progress bar reserved for traversal; the remainder is consumed by
    /// the assembly (finalization) phase, with the final point reserved for completion.
    /// Assembly is ~20% of wall time on real home-dir scans (dedup included), so it gets
    /// a visible slice of the bar rather than the last few points. Internal because the
    /// incremental rescan band must stay below it or the bar would step backward when
    /// finalization begins.
    nonisolated static let traversalSpan = 0.9
    private nonisolated static let finalizationCeiling = 0.99
    /// Upper bound on the geometric expansion applied per frontier directory when
    /// extrapolating how many descendants it will yield.
    private nonisolated static let maxFrontierExpansion = 6.0

    public nonisolated var progressPercentage: Int {
        Int((progressFraction * 100).rounded(.down))
    }

    public nonisolated mutating func recalculateProgress(isComplete: Bool = false) {
        if isComplete {
            progressFraction = 1
            return
        }

        if isFinalizing {
            let assembled = min(max(finalizationFraction, 0), 1)
            let fraction = Self.traversalSpan + (Self.finalizationCeiling - Self.traversalSpan) * assembled
            progressFraction = max(progressFraction, fraction)
            return
        }

        var traversalFraction = min(max(completedTraversalWeight, 0), 1)

        // The weight model overshoots in skewed trees (a directory's weight is split when
        // it is enumerated, before its true size is known). Cap it with an item-count
        // extrapolation: completed items versus discovered items plus the expected yield
        // of the unenumerated frontier, based on the branching observed so far.
        //
        // Apply the cap whenever discovered items remain unprocessed, not only when the
        // frontier still holds unenumerated directories. A large flat directory drains the
        // frontier to zero (no child subdirectories) while leaving thousands of discovered
        // files uncompleted; without this the weight estimate alone can leap near the
        // traversal ceiling before those files are scanned.
        if enumeratedDirectoryCount > 0, completedItems < discoveredItems || pendingDirectoryCount > 0 {
            let enumerated = Double(enumeratedDirectoryCount)
            let childrenPerDirectory = Double(discoveredItems) / enumerated
            let subdirectoriesPerDirectory = Double(discoveredDirectoryCount) / enumerated
            let expansion = subdirectoriesPerDirectory < 1
                ? min(1 / (1 - subdirectoriesPerDirectory), Self.maxFrontierExpansion)
                : Self.maxFrontierExpansion
            let expectedFrontierYield = Double(pendingDirectoryCount) * childrenPerDirectory * expansion
            let countFraction = min(
                (Double(completedItems) + enumerated) / (Double(discoveredItems) + expectedFrontierYield),
                1
            )
            traversalFraction = min(traversalFraction, countFraction)
        }

        if estimatedTotalBytes > 0 {
            // Volume scans know the volume's used capacity up front; blending the byte
            // ratio in smooths the coarser weight-based estimate.
            let byteFraction = min(Double(bytesDiscovered) / Double(estimatedTotalBytes), 1)
            traversalFraction = (traversalFraction + byteFraction) / 2
        }

        let hasStarted = filesVisited > 0 || directoriesVisited > 0 || discoveredItems > 0
        let minimumVisibleProgress = hasStarted ? 0.01 : 0
        progressFraction = max(progressFraction, max(traversalFraction * Self.traversalSpan, minimumVisibleProgress))
    }
}

public enum ScanProgressEvent: Sendable {
    case progress(ScanMetrics)
    case warning(ScanWarning)
    /// A best-effort tree of everything scanned so far, emitted periodically
    /// during traversal so the UI can render a live, growing treemap.
    /// Directory sizes only include children visited so far and no hard-link
    /// deduplication is applied; `finished` supersedes it with exact data.
    case partial(FileTreeStore)
    case finished(ScanSnapshot)
}
