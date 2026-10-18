import Foundation

/// Moved out of the main file for size; `internal` because Swift `private` is file-scoped. Not public API.
extension ScanTraversal {
    struct AggregateStatsAccumulator {
        private(set) var fileCount = 0
        private(set) var directoryCount = 0
        private(set) var accessibleItemCount = 0
        private(set) var inaccessibleItemCount = 0

        mutating func include(_ node: FileNodeRecord, hasChildren: Bool) {
            if node.isDirectory {
                directoryCount += 1
                if node.isPackage && !hasChildren {
                    fileCount += node.descendantFileCount
                }
                if node.isAutoSummarized {
                    fileCount += node.descendantFileCount
                }
            } else if !node.isSymbolicLink && !node.isSynthetic {
                fileCount += 1
            }

            if node.isAccessible {
                accessibleItemCount += 1
            } else {
                inaccessibleItemCount += 1
            }
        }

        func makeStats(root: FileNodeRecord) -> ScanAggregateStats {
            ScanAggregateStats(
                totalAllocatedSize: root.allocatedSize,
                totalLogicalSize: root.logicalSize,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessibleItemCount: accessibleItemCount,
                inaccessibleItemCount: inaccessibleItemCount
            )
        }
    }

    /// `weight` is this subtree's share of total progress (root is 1), split among children on enumeration.
    struct ScanWorkItem: Sendable {
        let url: URL
        /// Materialized once so the loop doesn't re-derive `url.path` per popped item.
        let path: String
        let metadata: NodeMetadata?
        let localizedEnumerationError: Error?
        let isDirectoryHint: Bool?
        let blocksTraversalAtMountBoundary: Bool
        let parentKey: Int
        let depth: Int
        let weight: Double
        /// Inside another app's container: read on the container lane
        /// (`ProtectedContainers`).
        var isInProtectedContainer = false
    }

    struct DirectoryTraversalSuccess: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: ScanEngine.DirectoryContentsScanResult
        let leafBatch: DirectoryLeafBatch
    }

    /// Resolved on the worker, so the coordinator only stamps parent-relative fields: O(1) per child instead of
    /// rebuilding each URL and re-classifying.
    struct PendingChildWorkItem: Sendable {
        let url: URL
        let path: String
        let metadata: NodeMetadata?
        let localizedEnumerationError: Error?
        let isDirectoryHint: Bool?
        let blocksTraversalAtMountBoundary: Bool
        /// 1 for a leaf, `directoryChildWeightUnits` for a directory; scaled by the parent's weight.
        let weightUnits: Double
    }

    /// Directories, packages and unreadable entries become `pendingChildWorkItems` instead.
    struct DirectoryLeafBatch: Sendable {
        var nodes: [FileNodeRecord] = []
        var pendingChildWorkItems: [PendingChildWorkItem] = []
        var hardLinkClaims: [HardLinkClaim] = []
        var duplicateWarnings: [ScanWarning] = []
        var duplicateWeightUnits = 0.0
        var fileCount = 0
        var allocatedSize: Int64 = 0
        /// The folder's own `url.path` and display name, derived on its task.
        var urlPathAndName: (path: String, name: String)?
        /// The leaves' totals for live partial trees, summed on the worker.
        var leafTotals = ScanEngine.PartialSubtreeTotals()
        /// Duplicates included; computed on the worker so frontier bookkeeping is O(1).
        var childDirectoryCount = 0
        /// Values are exactly representable (1 or `directoryChildWeightUnits`), so the sum is order-independent.
        var totalWeightUnits = 0.0

        var completedEntryCount: Int {
            nodes.count + duplicateWarnings.count
        }

        var completedWeightUnits: Double {
            Double(nodes.count) + duplicateWeightUnits
        }
    }

    /// One finalized child reference. Keyed children are directories,
    /// packages, or unavailable entries; ordinary leaves stay as values.
    enum AssemblyChildReference {
        case keyed(Int)
        case direct(FileNodeRecord)
    }

    struct DirectoryTraversalFailure: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let warning: ScanWarning
        #if DEBUG
        let elapsedNanoseconds: UInt64
        let diagnosticDetail: String
        #endif

        #if DEBUG
        init(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning,
            elapsedNanoseconds: UInt64,
            diagnosticDetail: String
        ) {
            self.item = item
            self.itemKey = itemKey
            self.metadata = metadata
            self.warning = warning
            self.elapsedNanoseconds = elapsedNanoseconds
            self.diagnosticDetail = diagnosticDetail
        }
        #else
        init(
            item: ScanWorkItem,
            itemKey: Int,
            metadata: NodeMetadata,
            warning: ScanWarning
        ) {
            self.item = item
            self.itemKey = itemKey
            self.metadata = metadata
            self.warning = warning
        }
        #endif
    }

    enum DirectoryTraversalResult: Sendable {
        case success(DirectoryTraversalSuccess)
        case failure(DirectoryTraversalFailure)
    }

    /// A summarized package leaf produced off the loop by a pooled summary task.
    struct PackageSummaryOutcome: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let leaf: LeafNodeResult
    }

    /// An enumerated directory that passed the cheap auto-summarize gate and is
    /// awaiting its pooled probe/summary off the loop.
    struct AtomicDirectoryCandidate: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: ScanEngine.DirectoryContentsScanResult
        let leafBatch: DirectoryLeafBatch
        let childDirectoryCount: Int
        let isNodeDependencyLayout: Bool
    }

    struct AtomicDirectoryOutcome: Sendable {
        let candidate: AtomicDirectoryCandidate
        /// nil when the probe decided the directory should be expanded normally.
        let summary: AtomicDirectorySummary?
    }

    /// The result classes multiplexed through the scan's single task group.
    enum ScanTaskOutcome: Sendable {
        case directory(DirectoryTraversalResult)
        case package(PackageSummaryOutcome)
        case atomicDirectory(AtomicDirectoryOutcome)
    }

    /// Thresholds for automatically summarizing directories with many small files.
    /// Directories exceeding BOTH thresholds are treated as atomic (not expanded).
    enum AtomicDirectoryThresholds {
        /// Minimum file count to consider a directory for atomic treatment
        static let minFileCount = 5_000
        /// Maximum average file size (in bytes) to consider for atomic treatment
        /// Below this suggests files are tiny/cached/irrelevant (npm, caches, etc.)
        static let maxAverageFileSize: Int64 = 4_096  // 4 KB average
        /// Minimum depth at which atomic treatment applies
        /// (depth 0 = scan root, depth 1 = immediate children, etc.)
        static let minDepthForSummarization = 2
    }
}
