import Foundation

public struct ScanMetrics: Sendable {
    public init() {}

    public var filesVisited = 0
    public var directoriesVisited = 0
    public var bytesDiscovered: Int64 = 0
    public var currentPath = ""
    var discoveredItems = 0
    var completedItems = 0
    var estimatedTotalBytes: Int64 = 0
    /// The root weighs 1 and each directory splits its weight among its children when enumerated,
    /// so completed weights converge to 1 exactly as traversal finishes.
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
    /// No counters move during this phase, so the strip needs the flag to show activity.
    public var isCheckingChanges = false
    /// Lets the strip say so instead of looking like a long rescan. The root-relist path never sets it.
    public var isFullScanFallback = false

    /// Assembly is ~20% of wall time on real scans, so it gets a visible slice. Internal because the
    /// incremental rescan band must stay below it or the bar steps back when finalization begins.
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

        // Weight overshoots in skewed trees, so cap it with an item-count estimate whenever items remain:
        // a large flat directory drains the frontier while its files are still pending.
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
    /// Sizes include only children visited so far and skip hard-link dedup; `finished` supersedes it.
    case partial(FileTreeStore)
    case finished(ScanSnapshot)
}
