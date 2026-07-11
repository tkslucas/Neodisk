//
//  ScanTraversal.swift
//  Neodisk
//

import Darwin
import Dispatch
import Foundation

/// One scan's traversal + assembly state, extracted from what used to be a
/// ~640-line `ScanEngine.scanDirectory` that threaded metrics, warnings and
/// emission state as `inout` parameters through six-plus call levels.
///
/// Deliberately a non-`Sendable` final class confined to the scan task: the
/// mutable state is only ever touched from that task. Task-group child tasks
/// capture nothing but immutable `Sendable` configuration (copied into
/// locals) and hand their results back through the group, exactly as the
/// pre-extraction code did.
nonisolated final class ScanTraversal {
    private typealias CompletedDirScan = ScanEngine.CompletedDirScan

    private struct AggregateStatsAccumulator {
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
    private struct ScanWorkItem: Sendable {
        let url: URL
        let metadata: NodeMetadata?
        let localizedEnumerationError: Error?
        let isDirectoryHint: Bool?
        let parentKey: Int
        let depth: Int
        let weight: Double
    }

    private struct DirectoryTraversalSuccess: Sendable {
        let item: ScanWorkItem
        let itemKey: Int
        let metadata: NodeMetadata
        let contents: ScanEngine.DirectoryContentsScanResult
    }

    private struct DirectoryTraversalFailure: Sendable {
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

    private enum DirectoryTraversalResult: Sendable {
        case success(DirectoryTraversalSuccess)
        case failure(DirectoryTraversalFailure)
    }

    /// Thresholds for automatically summarizing directories with many small files.
    /// Directories exceeding BOTH thresholds are treated as atomic (not expanded).
    private enum AtomicDirectoryThresholds {
        /// Minimum file count to consider a directory for atomic treatment
        static let minFileCount = 5_000
        /// Maximum average file size (in bytes) to consider for atomic treatment
        /// Below this suggests files are tiny/cached/irrelevant (npm, caches, etc.)
        static let maxAverageFileSize: Int64 = 4_096  // 4 KB average
        /// Minimum depth at which atomic treatment applies
        /// (depth 0 = scan root, depth 1 = immediate children, etc.)
        static let minDepthForSummarization = 2
    }

    // MARK: - Immutable per-scan configuration

    private let target: ScanTarget
    private let includeVolumeDetails: Bool
    private let options: ScanOptions
    private let behavior: ScanEngine.ScanBehavior
    private let exclusionMatcher: ScanExclusionMatcher
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private let metadataLoader: ScanMetadataLoader
    private let directoryContents: ScanEngine.DirectoryContentsProvider
    private let atomicDirectorySummarizer: AtomicDirectorySummarizer
    private let volumeFileSystemTypeProvider: ScanEngine.VolumeFileSystemTypeProvider
    private let diagnostics: ScanDiagnosticsContext?
    private let bulkEnumerationEnabled: Bool
    private let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }
    private let atomicSummaryWorkerLimit: Int

    // MARK: - Mutable traversal state (scan-task confined)

    private(set) var metrics: ScanMetrics
    private(set) var warnings: [ScanWarning]
    private(set) var emissionState: ScanEmissionState
    private var hardLinkClaims: [HardLinkClaim] = []
    private var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
    private var concurrency: AdaptiveScanConcurrency
    private var workStack: [ScanWorkItem] = []
    /// Maps a key to its completed result (leaf or assembled directory).
    private var completedByKey: [Int: CompletedDirScan] = [:]
    /// Maps parent key → child keys, built during phase 1.
    private var childrenKeysByKey: [Int: [Int]] = [:]
    private var seenScannedNodeIDs = Set<String>()
    private var nextKey = 0
    // Live partial-tree emission: the first partial goes out as soon as
    // the root listing is in; afterwards the interval adapts to assembly
    // cost so partial builds never consume more than ~10% of scan time.
    private var lastPartialEmission = ContinuousClock.now - .milliseconds(300)
    private var partialEmissionInterval: Duration = .milliseconds(300)

    init(
        target: ScanTarget,
        includeVolumeDetails: Bool,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        metadataLoader: ScanMetadataLoader,
        directoryContents: @escaping ScanEngine.DirectoryContentsProvider,
        atomicDirectorySummarizer: AtomicDirectorySummarizer,
        volumeFileSystemTypeProvider: @escaping ScanEngine.VolumeFileSystemTypeProvider,
        diagnostics: ScanDiagnosticsContext?,
        bulkEnumerationEnabled: Bool,
        metrics: ScanMetrics,
        warnings: [ScanWarning],
        emissionState: ScanEmissionState
    ) {
        self.target = target
        self.includeVolumeDetails = includeVolumeDetails
        self.options = options
        self.behavior = behavior
        self.exclusionMatcher = exclusionMatcher
        self.continuation = continuation
        self.metadataLoader = metadataLoader
        self.directoryContents = directoryContents
        self.atomicDirectorySummarizer = atomicDirectorySummarizer
        self.volumeFileSystemTypeProvider = volumeFileSystemTypeProvider
        self.diagnostics = diagnostics
        self.bulkEnumerationEnabled = bulkEnumerationEnabled
        self.atomicSummaryWorkerLimit = ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options)
        self.concurrency = AdaptiveScanConcurrency(
            options: options,
            bulkEnumeration: bulkEnumerationEnabled
        )
        self.metrics = metrics
        self.warnings = warnings
        self.emissionState = emissionState
    }

    // MARK: - Entry point

    /// Scans the target's directory iteratively (no recursion) and returns a
    /// fully assembled flat tree.
    func run() async throws -> FileTreeStore {
        try Task.checkCancellation()

        let rootMetadata = try metadataLoader.metadata(for: target.url, includeVolumeDetails: includeVolumeDetails)
        metrics.discoveredItems = 1
        metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress()

        // If the root itself shouldn't be traversed, return a leaf node.
        guard shouldTraverseDirectory(metadata: rootMetadata, isRoot: true) else {
            return try await makeRootLeafStore(rootMetadata: rootMetadata)
        }

        try await runTraversalPhase(rootMetadata: rootMetadata)
        return try assembleTree()
    }

    private func makeRootLeafStore(rootMetadata: NodeMetadata) async throws -> FileTreeStore {
        let leafResult = try await makeLeafNode(url: target.url, metadata: rootMetadata)
        hardLinkClaims.append(contentsOf: leafResult.hardLinkClaims)
        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
        }
        applyLeafMetrics(leafResult.node, weight: 1)
        if !leafResult.warnings.isEmpty {
            warnings.append(contentsOf: leafResult.warnings)
            for warning in leafResult.warnings {
                continuation.yield(.warning(warning))
            }
        }
        continuation.yield(.progress(metrics))
        var leafNodes = [leafResult.node]
        var leafChildSlots: [Int32] = []
        HardLinkDeduplicator.applyDeduplication(
            nodes: &leafNodes,
            parentIndices: [-1],
            childStarts: [0, 0],
            childSlots: &leafChildSlots,
            indexByID: [leafResult.node.id: 0],
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: leafNodes,
                parentIndices: [-1],
                childStarts: [0, 0],
                childSlots: leafChildSlots,
                indexByID: [leafResult.node.id: 0]
            ),
            rootID: leafResult.node.id
        )
    }

    // MARK: - Phase 1: Traversal

    /// Phase 1: Walk the tree iteratively, collecting completed nodes by key.
    /// We use a stack for DFS. Each item knows its parent key and depth for assembly.
    private func runTraversalPhase(rootMetadata: NodeMetadata) async throws {
        metrics.discoveredDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        workStack = [
            ScanWorkItem(
                url: target.url,
                metadata: rootMetadata,
                localizedEnumerationError: nil,
                isDirectoryHint: nil,
                parentKey: -1,
                depth: 0,
                weight: 1
            )
        ]

        // Local, Sendable copies for the task-group child tasks: capturing
        // these (instead of `self`) keeps the non-Sendable traversal state
        // confined to the scan task.
        let options = self.options
        let behavior = self.behavior
        let exclusionMatcher = self.exclusionMatcher
        let cancellationCheck = self.cancellationCheck
        let scanMetadataLoader = metadataLoader
        let directoryContentsProvider = directoryContents
        let directoryResourceKeys = ScanMetadataLoader.scanResourceKeys
        let usesBulkEnumeration = bulkEnumerationEnabled

        try await withThrowingTaskGroup(of: DirectoryTraversalResult.self) { group in
            var activeDirectoryTasks = 0

            while true {
                concurrency.refreshIfDue()
                while activeDirectoryTasks < concurrency.traversalWorkerLimit,
                      let item = workStack.popLast() {
                    try Task.checkCancellation()

                    guard seenScannedNodeIDs.insert(item.url.path).inserted else {
                        releasePendingDirectoryIfNeeded(for: item)
                        recordDuplicateNode(at: item.url, weight: item.weight)
                        continue
                    }

                    let itemKey = nextKey
                    nextKey += 1

                    // Register this child with its parent (skip root which has parentKey -1).
                    if item.parentKey >= 0 {
                        childrenKeysByKey[item.parentKey, default: []].append(itemKey)
                    }

                    let meta: NodeMetadata
                    if let localizedEnumerationError = item.localizedEnumerationError {
                        releasePendingDirectoryIfNeeded(for: item)
                        recordUnavailableItem(item, itemKey: itemKey, error: localizedEnumerationError)
                        continue
                    } else if let itemMetadata = item.metadata {
                        meta = itemMetadata
                    } else {
                        do {
                            meta = try metadataLoader.metadata(for: item.url)
                        } catch {
                            releasePendingDirectoryIfNeeded(for: item)
                            recordUnavailableItem(item, itemKey: itemKey, error: error)
                            continue
                        }
                    }
                    metrics.currentPath = item.url.path

                    if shouldTraverseDirectory(metadata: meta, isRoot: item.depth == 0) {
                        metrics.directoriesVisited += 1
                        metrics.recalculateProgress()
                        maybeEmitProgress()

                        let taskItem = item
                        let taskItemKey = itemKey
                        let taskMetadata = meta
                        let taskClassificationWorkerLimit = concurrency.classificationWorkerLimit
                        activeDirectoryTasks += 1
                        group.addTask {
                            #if DEBUG
                            let traversalStart = DispatchTime.now().uptimeNanoseconds
                            #endif
                            do {
                                let contents = try await ScanEngine.directoryEntries(
                                    of: taskItem.url,
                                    includeHiddenFiles: options.includeHiddenFiles,
                                    behavior: behavior,
                                    exclusionMatcher: exclusionMatcher,
                                    resourceKeys: directoryResourceKeys,
                                    metadataLoader: scanMetadataLoader,
                                    directoryContents: directoryContentsProvider,
                                    classificationWorkerLimit: taskClassificationWorkerLimit,
                                    usesBulkEnumeration: usesBulkEnumeration,
                                    cancellationCheck: cancellationCheck
                                )
                                return .success(DirectoryTraversalSuccess(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    contents: contents
                                ))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                #if DEBUG
                                return .failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error),
                                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - traversalStart,
                                    diagnosticDetail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
                                ))
                                #else
                                return .failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error)
                                ))
                                #endif
                            }
                        }
                    } else {
                        // Leaf node (file, symlink, or package-as-directory). Discovery may
                        // have classified it as a pending directory; release that claim.
                        releasePendingDirectoryIfNeeded(for: item)
                        try await completeLeaf(item: item, itemKey: itemKey, metadata: meta)
                    }
                }

                guard activeDirectoryTasks > 0 else { break }
                guard let traversalResult = try await group.next() else { break }
                activeDirectoryTasks -= 1

                switch traversalResult {
                case .success(let success):
                    try await handleTraversalSuccess(success)
                case .failure(let failure):
                    handleTraversalFailure(failure)
                }

                maybeEmitPartialTree()
            }
        }
    }

    private func completeLeaf(item: ScanWorkItem, itemKey: Int, metadata meta: NodeMetadata) async throws {
        let leafResult = try await makeLeafNode(url: item.url, metadata: meta)
        hardLinkClaims.append(contentsOf: leafResult.hardLinkClaims)
        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
        }
        applyLeafMetrics(leafResult.node, weight: item.weight)
        if !leafResult.warnings.isEmpty {
            warnings.append(contentsOf: leafResult.warnings)
            for warning in leafResult.warnings {
                continuation.yield(.warning(warning))
            }
        }
        maybeEmitProgress()

        completedByKey[itemKey] = CompletedDirScan(
            node: leafResult.node,
            metadata: meta,
            url: item.url,
            isTraversable: false,
            depth: item.depth
        )
    }

    private func handleTraversalSuccess(_ success: DirectoryTraversalSuccess) async throws {
        let item = success.item
        let itemKey = success.itemKey
        let meta = success.metadata
        let contents = success.contents
        let childEntries = contents.entries
        #if DEBUG
        diagnostics?.recordElapsed(
            operation: "directory.enumerate",
            url: item.url,
            nanoseconds: contents.enumerationNanoseconds,
            itemCount: contents.enumeratedItemCount
        )
        diagnostics?.recordElapsed(
            operation: "directory.classify_children",
            url: item.url,
            nanoseconds: contents.classificationNanoseconds,
            itemCount: contents.enumeratedItemCount,
            detail: "kept=\(childEntries.count)"
        )
        #endif

        metrics.currentPath = item.url.path
        metrics.discoveredItems += childEntries.count
        metrics.enumeratedDirectoryCount += 1
        releasePendingDirectoryIfNeeded(for: item)
        var childDirectoryCount = 0
        for childEntry in childEntries
        where Self.isLikelyTraversableDirectory(entry: childEntry) {
            childDirectoryCount += 1
        }
        metrics.discoveredDirectoryCount += childDirectoryCount
        metrics.pendingDirectoryCount += childDirectoryCount
        metrics.recalculateProgress()
        maybeEmitProgress()

        // Check if this directory should be summarized as atomic (many small files)
        let minFileCount = options.tuning.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
        let maxAvgSize = options.tuning.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize
        let minDepth = options.tuning.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization
        let isNodeDependencyLayout = AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(at: item.url)
        let isKnownGeneratedDirectory = AtomicDirectorySummarizer.isKnownGeneratedDirectory(at: item.url)
        let canProbeForAutoSummary =
            item.depth >= minDepth ||
            (item.depth >= 1 && isNodeDependencyLayout) ||
            isKnownGeneratedDirectory
        var completedAsAtomicDirectory = false
        if options.autoSummarizeDirectories,
           canProbeForAutoSummary,
           let summary = try await atomicDirectorySummarizer.summaryIfNeeded(
               url: item.url,
               childEntries: childEntries,
               metadata: meta,
               includeHiddenFiles: options.includeHiddenFiles,
               treatPackagesAsDirectories: options.treatPackagesAsDirectories,
               isNodeDependencyLayout: isNodeDependencyLayout,
               minFileCount: minFileCount,
               maxAverageFileSize: maxAvgSize,
               workerLimit: atomicSummaryWorkerLimit,
               exclusionMatcher: exclusionMatcher,
               cancellationCheck: cancellationCheck,
               metrics: &metrics,
               continuation: continuation,
               emissionState: &emissionState
           ) {
            // Treat as atomic: create a leaf node with summary stats.
            let atomicNode = FileNodeRecord(
                id: item.url.path,
                url: item.url,
                name: ScanTarget.displayName(for: item.url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(meta.allocatedSize, summary.allocatedSize),
                logicalSize: max(meta.logicalSize, summary.logicalSize),
                descendantFileCount: summary.descendantFileCount,
                lastModified: meta.lastModified,
                fileIdentity: meta.fileIdentity,
                linkCount: meta.linkCount,
                isPackage: false,
                isAccessible: summary.isAccessible,
                isSelfAccessible: meta.isReadable,
                isSynthetic: false,
                isAutoSummarized: true
            )
            hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
            minimumAllocatedSizeByNodeID[atomicNode.id] = meta.allocatedSize
            // The summarized children will never be enqueued: count them as
            // completed and release their frontier claims.
            metrics.completedItems += childEntries.count
            metrics.discoveredDirectoryCount = max(
                metrics.discoveredDirectoryCount - childDirectoryCount,
                0
            )
            metrics.pendingDirectoryCount = max(metrics.pendingDirectoryCount - childDirectoryCount, 0)
            applyLeafMetrics(atomicNode, weight: item.weight)
            if !summary.warnings.isEmpty {
                warnings.append(contentsOf: summary.warnings)
                for warning in summary.warnings {
                    continuation.yield(.warning(warning))
                }
            }
            maybeEmitProgress()

            completedByKey[itemKey] = CompletedDirScan(
                node: atomicNode,
                metadata: meta,
                url: item.url,
                isTraversable: false,
                depth: item.depth
            )
            completedAsAtomicDirectory = true
        }

        guard !completedAsAtomicDirectory else { return }

        if childEntries.isEmpty {
            // Nothing below this directory: its whole weight is done.
            metrics.completedTraversalWeight += item.weight
            metrics.recalculateProgress()
        }

        // Split this directory's progress weight among its children.
        var totalWeightUnits = 0.0
        for childEntry in childEntries {
            totalWeightUnits += Self.traversalWeightUnits(for: childEntry)
        }

        // Enqueue children onto the stack. Each child records its parent key.
        for (offset, childEntry) in childEntries.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            workStack.append(
                ScanWorkItem(
                    url: childEntry.url,
                    metadata: childEntry.metadata,
                    localizedEnumerationError: childEntry.localizedEnumerationError,
                    isDirectoryHint: childEntry.isDirectoryHint,
                    parentKey: itemKey,
                    depth: item.depth + 1,
                    weight: item.weight * Self.traversalWeightUnits(for: childEntry) / totalWeightUnits
                )
            )
        }
        // Register this directory so phase 2 can assemble it.
        completedByKey[itemKey] = CompletedDirScan(
            node: nil,
            metadata: meta,
            url: item.url,
            isTraversable: true,
            depth: item.depth
        )
    }

    private func handleTraversalFailure(_ failure: DirectoryTraversalFailure) {
        #if DEBUG
        diagnostics?.recordElapsed(
            operation: "directory.enumerate.error",
            url: failure.item.url,
            nanoseconds: failure.elapsedNanoseconds,
            detail: failure.diagnosticDetail
        )
        #endif
        let item = failure.item
        let itemKey = failure.itemKey
        let meta = failure.metadata
        let warning = failure.warning
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += item.weight
        metrics.enumeratedDirectoryCount += 1
        releasePendingDirectoryIfNeeded(for: item)
        metrics.recalculateProgress()
        maybeEmitProgress()

        let inaccessibleNode = FileNodeRecord(
            id: item.url.path,
            url: item.url,
            name: ScanTarget.displayName(for: item.url),
            isDirectory: true,
            isSymbolicLink: meta.isSymbolicLink,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: meta.lastModified,
            fileIdentity: meta.fileIdentity,
            linkCount: meta.linkCount,
            isPackage: meta.isPackage,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
        completedByKey[itemKey] = CompletedDirScan(
            node: inaccessibleNode,
            metadata: meta,
            url: item.url,
            isTraversable: false,
            depth: item.depth
        )
    }

    private func maybeEmitPartialTree() {
        guard ContinuousClock.now - lastPartialEmission >= partialEmissionInterval else { return }
        let buildStart = ContinuousClock.now
        if let partialStore = ScanEngine.assemblePartialTree(
            completedByKey: completedByKey,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: nextKey
        ) {
            continuation.yield(.partial(partialStore))
        }
        lastPartialEmission = ContinuousClock.now
        let buildDuration = lastPartialEmission - buildStart
        partialEmissionInterval = max(.milliseconds(300), buildDuration * 10)
    }

    // MARK: - Phase 2: Assembly

    /// Phase 2: Assemble the tree bottom-up from completed results.
    /// Process keys in reverse order (children always have higher keys than parents).
    private func assembleTree() throws -> FileTreeStore {
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.finalizationFraction = 0
        metrics.recalculateProgress()
        continuation.yield(.progress(metrics))

        let finalizationTotal = max(completedByKey.count, 1)
        let finalizationProgressInterval = 512
        var finalizedItems = 0
        var resolvedNodeByKey: [Int: FileNodeRecord] = [:]
        var sortedChildKeysByKey: [Int: [Int]] = [:]
        resolvedNodeByKey.reserveCapacity(completedByKey.count)
        sortedChildKeysByKey.reserveCapacity(completedByKey.count)
        #if DEBUG
        let finalizationStart = diagnostics?.start()
        #endif
        for key in (0..<nextKey).reversed() {
            if finalizedItems.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let completed = completedByKey.removeValue(forKey: key) else { continue }
            finalizedItems += 1

            if completed.isTraversable {
                // Traversable directories must still be materialized when empty.
                let childKeys = childrenKeysByKey.removeValue(forKey: key) ?? []
                var childPairs: [(key: Int, node: FileNodeRecord)] = []
                childPairs.reserveCapacity(childKeys.count)
                for (offset, childKey) in childKeys.enumerated() {
                    if offset.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    if let childNode = resolvedNodeByKey[childKey] {
                        childPairs.append((childKey, childNode))
                    }
                }
                childPairs = ScanEngine.uniqueAssemblyPairs(childPairs)
                childPairs.sort { FileTreeStore.childDisplayOrder($0.node, $1.node) }
                try Task.checkCancellation()
                let assembled = FileNodeRecord.directory(
                    id: completed.url.path,
                    url: completed.url,
                    name: ScanTarget.displayName(for: completed.url),
                    children: childPairs.map(\.node),
                    lastModified: completed.metadata.lastModified,
                    fileIdentity: completed.metadata.fileIdentity,
                    linkCount: completed.metadata.linkCount,
                    isPackage: completed.metadata.isPackage,
                    isAccessible: completed.metadata.isReadable,
                    childrenAreSorted: true
                )
                resolvedNodeByKey[key] = assembled
                if !childPairs.isEmpty {
                    sortedChildKeysByKey[key] = childPairs.map(\.key)
                }

                metrics.completedItems = min(metrics.discoveredItems, metrics.completedItems + 1)
            } else if let onlyChild = completed.node {
                // Leaf node or inaccessible directory: use the child directly.
                resolvedNodeByKey[key] = onlyChild
            }

            if finalizedItems.isMultiple(of: finalizationProgressInterval) || finalizedItems == finalizationTotal {
                try Task.checkCancellation()
                metrics.finalizationFraction = Double(finalizedItems) / Double(finalizationTotal)
                metrics.recalculateProgress()
                continuation.yield(.progress(metrics))
            }
        }

        guard resolvedNodeByKey[0] != nil else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }

        // Lay the assembled tree out as contiguous preorder arrays — the
        // scan keys stay Int end to end; the only string-keyed work left is
        // one id → index insert per node.
        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        var indexByID = NodeIDIndex(minimumCapacity: resolvedNodeByKey.count)
        nodes.reserveCapacity(resolvedNodeByKey.count)
        parentIndices.reserveCapacity(resolvedNodeByKey.count)
        var aggregateStats = AggregateStatsAccumulator()
        var buildStack: [(key: Int, parent: Int32)] = [(0, -1)]
        while let (key, parent) = buildStack.popLast() {
            if nodes.count.isMultiple(of: 1_024) {
                try Task.checkCancellation()
            }
            guard let record = resolvedNodeByKey[key] else { continue }
            let index = Int32(nodes.count)
            if let existing = indexByID.updateValue(index, forKey: record.id) {
                // Should be impossible (phase 1 dedupes by path); drop the
                // duplicate subtree and keep the first occurrence.
                indexByID[record.id] = existing
                let warning = ScanWarningFactory.makeDuplicateNodeWarning(for: record.url)
                warnings.append(warning)
                continuation.yield(.warning(warning))
                continue
            }
            nodes.append(record)
            parentIndices.append(parent)
            let childKeys = sortedChildKeysByKey[key] ?? []
            aggregateStats.include(record, hasChildren: !childKeys.isEmpty)
            for childKey in childKeys.reversed() {
                buildStack.append((childKey, index))
            }
        }
        let (childStarts, initialChildSlots) = TreeStorage.childLayout(parentIndices: parentIndices)
        var childSlots = initialChildSlots

        HardLinkDeduplicator.applyDeduplication(
            nodes: &nodes,
            parentIndices: parentIndices,
            childStarts: childStarts,
            childSlots: &childSlots,
            indexByID: indexByID,
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID
        )
        #if DEBUG
        diagnostics?.record(
            operation: "scan.finalize",
            url: target.url,
            startedAt: finalizationStart,
            itemCount: finalizedItems
        )
        #endif

        guard let rootNode = nodes.first else {
            throw ScanEngine.ScanEngineError.missingRootNode
        }

        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        maybeEmitProgress()

        return FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: parentIndices,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: indexByID
            ),
            rootID: rootNode.id,
            aggregateStats: aggregateStats.makeStats(root: rootNode)
        )
    }

    // MARK: - Leaf construction

    private func makeFileNode(
        url: URL,
        metadata: NodeMetadata
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            allocatedSize: metadata.allocatedSize,
            logicalSize: metadata.logicalSize,
            descendantFileCount: metadata.isDirectory || metadata.isSymbolicLink ? 0 : 1,
            lastModified: metadata.lastModified,
            fileIdentity: metadata.fileIdentity,
            linkCount: metadata.linkCount,
            isPackage: metadata.isPackage,
            isAccessible: metadata.isReadable,
            isSelfAccessible: metadata.isReadable,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    private func makeLeafNode(
        url: URL,
        metadata: NodeMetadata
    ) async throws -> (
        node: FileNodeRecord,
        warnings: [ScanWarning],
        hardLinkClaims: [HardLinkClaim],
        minimumAllocatedSize: Int64?
    ) {
        try cancellationCheck()
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            return (
                node,
                [],
                HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                nil
            )
        }

        guard let summary = try await atomicDirectorySummarizer.summarize(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options),
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else {
            let node = makeFileNode(
                url: url,
                metadata: metadata
            )
            return (
                node,
                [],
                HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                nil
            )
        }

        return (
            FileNodeRecord(
                id: url.path,
                url: url,
                name: ScanTarget.displayName(for: url),
                isDirectory: true,
                isSymbolicLink: false,
                allocatedSize: max(metadata.allocatedSize, summary.allocatedSize),
                logicalSize: max(metadata.logicalSize, summary.logicalSize),
                descendantFileCount: summary.descendantFileCount,
                lastModified: metadata.lastModified,
                fileIdentity: metadata.fileIdentity,
                linkCount: metadata.linkCount,
                isPackage: true,
                isAccessible: metadata.isReadable && summary.isAccessible,
                isSelfAccessible: metadata.isReadable,
                isSynthetic: false,
                isAutoSummarized: false
            ),
            summary.warnings,
            summary.hardLinkClaims,
            metadata.allocatedSize
        )
    }

    private func makeUnavailableNode(for url: URL, isDirectory: Bool) -> FileNodeRecord {
        FileNodeRecord(
            id: url.path,
            url: url,
            name: ScanTarget.displayName(for: url),
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    // MARK: - Metrics & event helpers

    private func applyLeafMetrics(_ node: FileNodeRecord, weight: Double) {
        if node.isDirectory {
            if !node.isAutoSummarized {
                metrics.directoriesVisited += 1
            }
            metrics.filesVisited += node.descendantFileCount
        } else if !node.isSymbolicLink {
            metrics.filesVisited += 1
        }
        metrics.bytesDiscovered = metrics.bytesDiscovered.addingClamped(node.allocatedSize)
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        metrics.recalculateProgress()
    }

    /// Relative progress weight of a traversable directory child versus a single file.
    /// A subdirectory hides an unscanned subtree of unknown size, so it gets a larger
    /// share of its parent's weight than a file does.
    private static let directoryChildWeightUnits = 8.0

    /// Classifies an item the same way at discovery time and at pop time so the
    /// frontier accounting in `ScanMetrics` stays balanced.
    private static func isLikelyTraversableDirectory(
        metadata: NodeMetadata?,
        url: URL,
        isDirectoryHint: Bool? = nil
    ) -> Bool {
        guard let metadata else {
            return isDirectoryHint ?? url.hasDirectoryPath
        }
        return metadata.isDirectory && !metadata.isSymbolicLink
    }

    private static func traversalWeightUnits(for entry: DirectoryEntry) -> Double {
        isLikelyTraversableDirectory(entry: entry) ? directoryChildWeightUnits : 1
    }

    private static func isLikelyTraversableDirectory(entry: DirectoryEntry) -> Bool {
        isLikelyTraversableDirectory(
            metadata: entry.metadata,
            url: entry.url,
            isDirectoryHint: entry.isDirectoryHint
        )
    }

    /// Removes an item's frontier claim once its fate is known (enumerated, leaf,
    /// duplicate, or unavailable). Uses the same classifier as discovery so the
    /// pending count stays balanced.
    private func releasePendingDirectoryIfNeeded(for item: ScanWorkItem) {
        guard Self.isLikelyTraversableDirectory(
            metadata: item.metadata,
            url: item.url,
            isDirectoryHint: item.isDirectoryHint
        ) else { return }
        metrics.pendingDirectoryCount = max(metrics.pendingDirectoryCount - 1, 0)
    }

    private func recordDuplicateNode(at url: URL, weight: Double) {
        let warning = ScanWarningFactory.makeDuplicateNodeWarning(for: url)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += weight
        metrics.recalculateProgress()
        maybeEmitProgress()
    }

    private func recordUnavailableItem(_ item: ScanWorkItem, itemKey: Int, error: Error) {
        let isDirectory = Self.isLikelyTraversableDirectory(
            metadata: item.metadata,
            url: item.url,
            isDirectoryHint: item.isDirectoryHint
        )
        let warning = ScanWarningFactory.makeWarning(for: item.url, error: error)
        warnings.append(warning)
        continuation.yield(.warning(warning))
        metrics.completedItems += 1
        metrics.completedTraversalWeight += item.weight
        metrics.recalculateProgress()
        maybeEmitProgress()

        completedByKey[itemKey] = CompletedDirScan(
            node: makeUnavailableNode(for: item.url, isDirectory: isDirectory),
            metadata: NodeMetadata(
                isDirectory: isDirectory,
                isPackage: false,
                isSymbolicLink: false,
                logicalSize: 0,
                allocatedSize: 0,
                lastModified: nil,
                isReadable: false,
                volumeUsedCapacity: nil,
                fileIdentity: nil,
                linkCount: 0
            ),
            url: item.url,
            isTraversable: false,
            depth: item.depth
        )
    }

    private func maybeEmitProgress() {
        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastProgressEmission)
        let shouldEmit = visitedItems <= 2 || visitedItems.isMultiple(of: 1_000) || elapsed >= 0.15
        guard shouldEmit else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }

    private func shouldTraverseDirectory(metadata: NodeMetadata, isRoot: Bool = false) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        guard metadata.isPackage else { return true }
        return options.treatPackagesAsDirectories
            || (isRoot && options.treatRootPackageAsDirectory)
    }

    /// Capacity reconciliation is useful on non-APFS volumes where per-file allocated
    /// sizes can miss reserved filesystem space. APFS container capacity is shared,
    /// so its free-space delta can overstate the scanned volume.
    private func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        guard target.kind == .volume,
              let volumeUsedCapacity = metadata.volumeUsedCapacity,
              shouldReconcileVolumeCapacity(for: target.url) else {
            return 0
        }
        return max(volumeUsedCapacity, metadata.allocatedSize)
    }

    private func shouldReconcileVolumeCapacity(for url: URL) -> Bool {
        guard let fileSystemType = volumeFileSystemTypeProvider(url) else {
            return false
        }
        let normalizedType = fileSystemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedType.isEmpty && normalizedType != "apfs"
    }
}
