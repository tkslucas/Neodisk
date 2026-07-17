//
//  ScanTraversalModels.swift
//  Neodisk
//

import Foundation

/// Value types threaded through `ScanTraversal`. Declared in an
/// `extension ScanTraversal` so call sites keep their `ScanTraversal`-nested
/// names; moved out of the main file purely to keep it a manageable size.
///
/// These were `private` when nested in the class body. Splitting them into a
/// separate file promotes them to `internal` (Swift `private` is file-scoped),
/// which is the minimum access that lets `ScanTraversal`'s methods in the core
/// file still reference them. They remain namespaced under `ScanTraversal` and
/// are not part of NeodiskKit's public API.
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

    /// A work item for the iterative scanner.
    /// `parentKey` links this item back to its parent for bottom-up assembly.
    /// `depth` tracks how deep we are in the directory tree.
    /// `weight` is this subtree's share of the scan's total progress (the root is 1);
    /// a directory's weight is split among its children when it is enumerated.
    struct ScanWorkItem: Sendable {
        let url: URL
        let metadata: NodeMetadata?
        let localizedEnumerationError: Error?
        let isDirectoryHint: Bool?
        let blocksTraversalAtMountBoundary: Bool
        let parentKey: Int
        let depth: Int
        let weight: Double
    }

    struct DirectoryTraversalSuccess: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: ScanEngine.DirectoryContentsScanResult
        let leafBatch: DirectoryLeafBatch
    }

    /// Ordinary files and symlinks built by a directory worker. Directories,
    /// packages, and entries whose metadata could not be read remain in
    /// `remainingEntries` and keep the coordinator's existing path.
    struct DirectoryLeafBatch: Sendable {
        var nodes: [FileNodeRecord] = []
        var remainingEntries: [DirectoryEntry] = []
        var hardLinkClaims: [HardLinkClaim] = []
        var duplicateWarnings: [ScanWarning] = []
        var duplicateWeightUnits = 0.0
        var fileCount = 0
        var allocatedSize: Int64 = 0

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
