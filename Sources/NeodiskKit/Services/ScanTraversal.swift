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

    // MARK: - Immutable per-scan configuration

    private let target: ScanTarget
    private let includeVolumeDetails: Bool
    private let options: ScanOptions
    private let behavior: ScanEngine.ScanBehavior
    private let exclusionMatcher: ScanExclusionMatcher
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private let metadataLoader: ScanMetadataLoader
    private let directoryContents: ScanEngine.DirectoryContentsProvider
    /// `var` because `run()` rebinds it to the run-scoped summary pool.
    private var atomicDirectorySummarizer: AtomicDirectorySummarizer
    /// The scan-wide pool that owns every package/atomic summary for this run.
    /// Created and torn down in `run()`.
    private var summaryPool: AtomicDirectorySummaryPool?
    private let volumeFileSystemTypeProvider: ScanEngine.VolumeFileSystemTypeProvider
    private let diagnostics: ScanDiagnosticsContext?
    private let bulkEnumerationEnabled: Bool
    private let cancellationCheck: CancellationCheck = { try Task.checkCancellation() }
    private let atomicSummaryWorkerLimit: Int
    /// The scan root's depth in the tree this scan is a part of. Non-zero
    /// only for incremental subtree rescans, where depth-gated behavior
    /// (auto-summarize thresholds) must fire exactly as it would have in
    /// the full scan that produced the baseline.
    private let baseDepth: Int

    // MARK: - Mutable traversal state (scan-task confined)

    private(set) var metrics: ScanMetrics
    private(set) var warnings: [ScanWarning]
    private(set) var emissionState: ScanEmissionState
    private var hardLinkClaims: [HardLinkClaim] = []
    private var minimumAllocatedSizeByNodeID: [String: Int64] = [:]
    private var concurrency: AdaptiveScanConcurrency
    private let directoryIOExecutor: DirectoryIOExecutor
    private var ownedDeviceIDs: Set<UInt64> = []
    private var workStack: [ScanWorkItem] = []
    /// Maps a key to its completed result (leaf or assembled directory).
    /// Keys are dense (0..<nextKey), allocated in the coordinator loop, so a
    /// flat array indexed by key beats a hash map: a nil slot is a key
    /// allocated but not yet completed (only observable during partial
    /// emission — every slot is filled by the time assembly runs).
    private var completedByKey: [CompletedDirScan?] = []
    /// Maps parent key → child keys, built during phase 1. Same dense-key
    /// array shape as `completedByKey`; a key with no children keeps `[]`.
    private var childrenKeysByKey: [[Int]] = []
    private var seenScannedNodeIDs = Set<String>()
    /// Prefetches clone members' private sizes during traversal so the
    /// clone-dedup assemble pass reads mostly-cached values. Created in `run()`.
    private var clonePrivateSizePrefetcher: ClonePrivateSizePrefetcher?
    private var nextKey = 0
    // Live partial-tree emission: the first partial goes out as soon as
    // the root listing is in; afterwards the interval adapts to assembly
    // cost so partial builds never consume more than ~10% of scan time.
    private var lastPartialEmission = ContinuousClock.now - .milliseconds(300)
    private var partialEmissionInterval: Duration = .milliseconds(300)
    /// Scan start reference for the time-to-first-partial timing; nilled
    /// after the first partial goes out.
    private var firstPartialReference: ContinuousClock.Instant? =
        ScanTiming.isEnabled ? .now : nil

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
        baseDepth: Int = 0,
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
        self.baseDepth = baseDepth
        self.atomicSummaryWorkerLimit = ScanConcurrencyPolicy.atomicSummaryWorkerLimit(for: options)
        let concurrency = AdaptiveScanConcurrency(
            options: options,
            bulkEnumeration: bulkEnumerationEnabled,
            sourceProfile: ScanSourceProfile.detect(for: target.url)
        )
        self.concurrency = concurrency
        // Sized to the nominal ceiling, not the current sample: the executor
        // pool is fixed for the scan's life, and a scan started under
        // thermal/low-power pressure must be able to speed back up when the
        // pressure clears. The adaptive in-flight limit does the throttling.
        self.directoryIOExecutor = DirectoryIOExecutor(
            workerCount: concurrency.undegradedTraversalWorkerLimit
        )
        self.metrics = metrics
        self.warnings = warnings
        self.emissionState = emissionState
    }

    // MARK: - Entry point

    /// Scans the target's directory iteratively (no recursion) and returns a
    /// fully assembled flat tree.
    func run() async throws -> FileTreeStore {
        // One shared worker pool per run owns every package/atomic summary, so a
        // giant bundle fans across all workers instead of stalling the loop while
        // siblings wait. Torn down on both the success and error paths.
        let pool = AtomicDirectorySummaryPool(
            workerLimit: atomicSummaryWorkerLimit,
            continuation: continuation
        )
        summaryPool = pool
        atomicDirectorySummarizer = atomicDirectorySummarizer.withSummaryPool(pool)
        pool.start()
        clonePrivateSizePrefetcher = ClonePrivateSizePrefetcher(
            workerLimit: ScanConcurrencyPolicy.cloneMetadataFetchWorkerLimit()
        )
        ScanSyscallTally.reset()

        do {
            try Task.checkCancellation()

            let rootMetadata = try metadataLoader.metadata(
                for: target.url,
                includeVolumeDetails: includeVolumeDetails,
                captureDirectoryIdentity: true
            )
            ownedDeviceIDs = MountBoundaryPolicy.ownedDeviceIDs(
                rootPath: target.url.path,
                rootDeviceID: rootMetadata.fileIdentity?.fileSystemDeviceID
            )
            metrics.discoveredItems = 1
            metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
            metrics.currentPath = target.url.path
            metrics.recalculateProgress()
            // Seeds the pool heartbeat's base metrics before any pooled work:
            // a root-leaf scan (package root) otherwise runs its whole summary
            // with the heartbeat dropping every emission.
            maybeEmitProgress()

            ScanTiming.note(
                "workers traversal=\(concurrency.traversalWorkerLimit) "
                + "classification=\(concurrency.classificationWorkerLimit) "
                + "nominal=\(concurrency.undegradedTraversalWorkerLimit) "
                + "summary=\(atomicSummaryWorkerLimit) bulk=\(bulkEnumerationEnabled)"
            )

            // If the root itself shouldn't be traversed, return a leaf node.
            let store: FileTreeStore
            if shouldTraverseDirectory(metadata: rootMetadata, isRoot: true) {
                try await ScanTiming.measure("scan.traversal", detail: "target=\(target.url.path)") {
                    try await runTraversalPhase(rootMetadata: rootMetadata)
                }
                store = try ScanTiming.measure("scan.assemble", detail: "keys=\(nextKey)") {
                    try assembleTree()
                }
            } else {
                store = try await makeRootLeafStore(rootMetadata: rootMetadata)
            }
            await pool.finish()
            ScanSyscallTally.emit()
            return store
        } catch {
            clonePrivateSizePrefetcher?.cancel()
            await pool.cancelAndFinish(with: error)
            throw error
        }
    }

    private func makeRootLeafStore(rootMetadata: NodeMetadata) async throws -> FileTreeStore {
        let leafResult = try await atomicDirectorySummarizer.makeLeafNode(
            url: target.url,
            metadata: rootMetadata,
            options: options,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        )
        hardLinkClaims.append(contentsOf: leafResult.hardLinkClaims)
        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
        }
        applyLeafMetrics(leafResult.node, weight: 1)
        summaryPool?.acknowledgeProgress(
            jobIDs: leafResult.progressJobIDs,
            foldedInto: metrics
        )
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
                indexByID: [leafResult.node.id: 0],
                nodeHashes: NodeIDIndex.parallelHashes(of: leafNodes)
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
                path: target.url.path,
                metadata: rootMetadata,
                localizedEnumerationError: nil,
                isDirectoryHint: nil,
                blocksTraversalAtMountBoundary: false,
                parentKey: -1,
                depth: baseDepth,
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
        let directoryIOExecutor = self.directoryIOExecutor
        let continuation = self.continuation
        // Set once in `run()` before this task group starts and never mutated
        // during traversal, so the workers capture an immutable Sendable copy
        // to resolve each child's mount-boundary flag off the coordinator.
        let ownedDeviceIDs = self.ownedDeviceIDs

        let summarizer = self.atomicDirectorySummarizer
        let summaryWorkerLimit = self.atomicSummaryWorkerLimit
        // Request cap for concurrent summary tasks. The shared pool bounds the
        // actual CPU (its worker count); this only limits how many summaries are
        // in flight so their probes and result plumbing don't pile up.
        let summaryRequestLimit = max(1, summaryWorkerLimit * 2)
        let autoSummarizeMinFileCount = options.tuning.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
        let autoSummarizeMaxAverageFileSize = options.tuning.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize

        try await withThrowingTaskGroup(of: ScanTaskOutcome.self) { group in
            var activeDirectoryTasks = 0
            // One counter for both package and atomic-directory summary tasks.
            var activeSummaryTasks = 0
            // Packages and atomic-summary candidates waiting for a request slot.
            // They must not be summarized inline in the scheduling loop: awaiting a
            // pool job there stops the group from draining, freezing progress
            // bookkeeping until the stack unwinds.
            var pendingPackageScans: [(item: ScanWorkItem, itemKey: Int, metadata: NodeMetadata)] = []
            var pendingAtomicScans: [AtomicDirectoryCandidate] = []

            while true {
                concurrency.refreshIfDue()
                while activeDirectoryTasks < concurrency.traversalWorkerLimit,
                      let item = workStack.popLast() {
                    try Task.checkCancellation()

                    guard seenScannedNodeIDs.insert(item.path).inserted else {
                        releasePendingDirectoryIfNeeded(for: item)
                        recordDuplicateNode(at: item.url, weight: item.weight)
                        continue
                    }

                    let itemKey = nextKey
                    nextKey += 1
                    // Grow the dense key arrays in lockstep with `nextKey`; the
                    // completed slot fills later at one of the completion sites.
                    completedByKey.append(nil)
                    childrenKeysByKey.append([])

                    // Register this child with its parent (skip root which has parentKey -1).
                    if item.parentKey >= 0 {
                        childrenKeysByKey[item.parentKey].append(itemKey)
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
                    metrics.currentPath = item.path

                    if shouldTraverseDirectory(
                        metadata: meta,
                        isRoot: item.depth == baseDepth,
                        blocksTraversalAtMountBoundary: item.blocksTraversalAtMountBoundary
                    ) {
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
                                    directoryIOExecutor: directoryIOExecutor,
                                    cancellationCheck: cancellationCheck
                                )
                                let leafBatch = try Self.makeDirectoryLeafBatch(
                                    from: contents.entries,
                                    ownedDeviceIDs: ownedDeviceIDs,
                                    summarizer: summarizer,
                                    cancellationCheck: cancellationCheck
                                )
                                return .directory(.success(DirectoryTraversalSuccess(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    contents: contents,
                                    leafBatch: leafBatch
                                )))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                #if DEBUG
                                return .directory(.failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error),
                                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - traversalStart,
                                    diagnosticDetail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
                                )))
                                #else
                                return .directory(.failure(DirectoryTraversalFailure(
                                    item: taskItem,
                                    itemKey: taskItemKey,
                                    metadata: taskMetadata,
                                    warning: ScanWarningFactory.makeWarning(for: taskItem.url, error: error)
                                )))
                                #endif
                            }
                        }
                    } else {
                        // Leaf node (file, symlink, or package-as-directory). Discovery may
                        // have classified it as a pending directory; release that claim.
                        releasePendingDirectoryIfNeeded(for: item)
                        if item.blocksTraversalAtMountBoundary, meta.isDirectory {
                            completeMountBoundary(
                                item: item,
                                itemKey: itemKey,
                                metadata: meta,
                                node: summarizer.makeFileNode(url: item.url, metadata: meta)
                            )
                        } else if meta.isPackage, meta.isDirectory, !options.treatPackagesAsDirectories {
                            // Defer the package summary to a request-limited task so
                            // it summarizes through the shared pool off the loop.
                            pendingPackageScans.append((item: item, itemKey: itemKey, metadata: meta))
                        } else {
                            try await completeLeaf(item: item, itemKey: itemKey, metadata: meta)
                        }
                    }
                }

                while activeSummaryTasks < summaryRequestLimit,
                      let pendingPackage = pendingPackageScans.popLast() {
                    let taskItem = pendingPackage.item
                    let taskItemKey = pendingPackage.itemKey
                    let taskMetadata = pendingPackage.metadata
                    let taskMetrics = metrics
                    let taskEmissionState = emissionState
                    activeSummaryTasks += 1
                    group.addTask {
                        var localMetrics = taskMetrics
                        var localEmissionState = taskEmissionState
                        let leaf = try await summarizer.makeLeafNode(
                            url: taskItem.url,
                            metadata: taskMetadata,
                            options: options,
                            exclusionMatcher: exclusionMatcher,
                            cancellationCheck: cancellationCheck,
                            metrics: &localMetrics,
                            continuation: continuation,
                            emissionState: &localEmissionState
                        )
                        return .package(PackageSummaryOutcome(
                            item: taskItem,
                            itemKey: taskItemKey,
                            metadata: taskMetadata,
                            leaf: leaf
                        ))
                    }
                }

                while activeSummaryTasks < summaryRequestLimit,
                      let candidate = pendingAtomicScans.popLast() {
                    let taskMetrics = metrics
                    let taskEmissionState = emissionState
                    activeSummaryTasks += 1
                    group.addTask {
                        var localMetrics = taskMetrics
                        var localEmissionState = taskEmissionState
                        let summary = try await summarizer.summaryIfNeeded(
                            url: candidate.item.url,
                            childEntries: candidate.contents.entries,
                            metadata: candidate.metadata,
                            includeHiddenFiles: options.includeHiddenFiles,
                            treatPackagesAsDirectories: options.treatPackagesAsDirectories,
                            isNodeDependencyLayout: candidate.isNodeDependencyLayout,
                            minFileCount: autoSummarizeMinFileCount,
                            maxAverageFileSize: autoSummarizeMaxAverageFileSize,
                            exclusionMatcher: exclusionMatcher,
                            cancellationCheck: cancellationCheck,
                            metrics: &localMetrics,
                            continuation: continuation,
                            emissionState: &localEmissionState
                        )
                        return .atomicDirectory(AtomicDirectoryOutcome(
                            candidate: candidate,
                            summary: summary
                        ))
                    }
                }

                guard activeDirectoryTasks + activeSummaryTasks > 0 else { break }
                guard let outcome = try await group.next() else { break }

                switch outcome {
                case .directory(.success(let success)):
                    activeDirectoryTasks -= 1
                    try handleTraversalSuccess(success, pendingAtomicScans: &pendingAtomicScans)
                case .directory(.failure(let failure)):
                    activeDirectoryTasks -= 1
                    handleTraversalFailure(failure)
                case .package(let packageOutcome):
                    activeSummaryTasks -= 1
                    completePackage(packageOutcome)
                case .atomicDirectory(let atomicOutcome):
                    activeSummaryTasks -= 1
                    try completeAtomicDirectory(atomicOutcome)
                }

                maybeEmitPartialTree()
            }
        }
    }

    /// Builds ordinary leaf records on the directory worker that already owns
    /// the enumerated child metadata. Iterating in reverse preserves the old
    /// work-stack duplicate rule (the last enumerated path wins).
    private static func makeDirectoryLeafBatch(
        from entries: [DirectoryEntry],
        ownedDeviceIDs: Set<UInt64>,
        summarizer: AtomicDirectorySummarizer,
        cancellationCheck: @escaping CancellationCheck
    ) throws -> DirectoryLeafBatch {
        var batch = DirectoryLeafBatch()
        batch.nodes.reserveCapacity(entries.count)
        batch.pendingChildWorkItems.reserveCapacity(min(entries.count, 64))
        var seenNodeIDs = Set<String>()

        for (offset, entry) in entries.reversed().enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }

            // Frontier + weight bookkeeping the coordinator used to redo
            // serially, folded into the pass that already visits every entry.
            // Accumulated across the whole listing (duplicates included) to
            // match the coordinator's former loops over `childEntries`.
            let entryIsDirectory = isLikelyTraversableDirectory(entry: entry)
            let weightUnits = entryIsDirectory ? directoryChildWeightUnits : 1
            batch.totalWeightUnits += weightUnits
            if entryIsDirectory {
                batch.childDirectoryCount += 1
            }

            let nodeID = entry.path
            guard seenNodeIDs.insert(nodeID).inserted else {
                batch.duplicateWarnings.append(
                    ScanWarningFactory.makeDuplicateNodeWarning(for: entry.url)
                )
                batch.duplicateWeightUnits += weightUnits
                continue
            }

            guard entry.localizedEnumerationError == nil,
                  let metadata = entry.metadata,
                  !metadata.isDirectory || metadata.isSymbolicLink else {
                batch.pendingChildWorkItems.append(
                    PendingChildWorkItem(
                        url: entry.url,
                        path: entry.path,
                        metadata: entry.metadata,
                        localizedEnumerationError: entry.localizedEnumerationError,
                        isDirectoryHint: entry.isDirectoryHint,
                        blocksTraversalAtMountBoundary: MountBoundaryPolicy.isNestedMount(
                            deviceID: entry.deviceID,
                            ownedDeviceIDs: ownedDeviceIDs,
                            directoryMountStatus: entry.directoryMountStatus
                        ),
                        weightUnits: weightUnits
                    )
                )
                continue
            }

            let node = summarizer.makeFileNode(path: entry.path, name: entry.name, metadata: metadata)
            batch.nodes.append(node)
            if node.cloneInfo != nil {
                batch.cloneMemberPaths.append(node.path)
            }
            if !node.isSymbolicLink {
                batch.fileCount += 1
            }
            batch.allocatedSize = batch.allocatedSize.addingClamped(node.allocatedSize)
            if let claim = HardLinkDeduplicator.claim(
                for: metadata,
                ownerNodeID: node.id,
                path: node.path
            ) {
                batch.hardLinkClaims.append(claim)
            }
        }

        // Restore enumeration order for deterministic fixtures. Final display
        // order is size/name sorted during assembly. Push order is behavioral:
        // the coordinator's global `seenScannedNodeIDs` is first-seen-wins, so
        // `pendingChildWorkItems` must reach the work stack in the same order
        // the old `remainingEntries` did.
        batch.nodes.reverse()
        batch.pendingChildWorkItems.reverse()
        batch.duplicateWarnings.reverse()
        return batch
    }

    /// Applies one directory worker's aggregate leaf accounting in O(1) loop
    /// interactions, then emits any exceptional duplicate warnings.
    private func foldDirectoryLeafBatch(
        _ batch: DirectoryLeafBatch,
        weightPerEntry: Double
    ) {
        hardLinkClaims.append(contentsOf: batch.hardLinkClaims)
        clonePrivateSizePrefetcher?.enqueue(paths: batch.cloneMemberPaths)
        metrics.filesVisited += batch.fileCount
        metrics.bytesDiscovered = metrics.bytesDiscovered.addingClamped(batch.allocatedSize)
        metrics.completedItems += batch.completedEntryCount
        metrics.completedTraversalWeight += weightPerEntry * batch.completedWeightUnits
        if !batch.duplicateWarnings.isEmpty {
            warnings.append(contentsOf: batch.duplicateWarnings)
            for warning in batch.duplicateWarnings {
                continuation.yield(.warning(warning))
            }
        }
        metrics.recalculateProgress()
        maybeEmitProgress()
    }

    private func completeLeaf(item: ScanWorkItem, itemKey: Int, metadata meta: NodeMetadata) async throws {
        let leafResult = try await atomicDirectorySummarizer.makeLeafNode(
            url: item.url,
            metadata: meta,
            options: options,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        )
        foldLeafResult(leafResult, item: item, itemKey: itemKey, metadata: meta)
    }

    /// Keeps an unintended nested mount visible without recursing into it or
    /// routing a package-shaped mount through recursive summary work.
    private func completeMountBoundary(
        item: ScanWorkItem,
        itemKey: Int,
        metadata: NodeMetadata,
        node: FileNodeRecord
    ) {
        applyLeafMetrics(node, weight: item.weight)
        maybeEmitProgress()
        completedByKey[itemKey] = CompletedDirScan(
            node: node,
            metadata: metadata,
            url: item.url,
            isTraversable: false,
            depth: item.depth
        )
    }

    /// Folds a completed leaf (plain file/symlink, or a summarized package) into
    /// the loop-side accounting and registers it for phase 2 assembly.
    private func foldLeafResult(
        _ leafResult: LeafNodeResult,
        item: ScanWorkItem,
        itemKey: Int,
        metadata meta: NodeMetadata
    ) {
        hardLinkClaims.append(contentsOf: leafResult.hardLinkClaims)
        if let minimumAllocatedSize = leafResult.minimumAllocatedSize {
            minimumAllocatedSizeByNodeID[leafResult.node.id] = minimumAllocatedSize
        }
        applyLeafMetrics(leafResult.node, weight: item.weight)
        summaryPool?.acknowledgeProgress(
            jobIDs: leafResult.progressJobIDs,
            foldedInto: metrics
        )
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

    /// Loop-side handling of an enumerated directory: frontier bookkeeping, then
    /// either deferring the auto-summary probe to a pooled task (`pendingAtomicScans`)
    /// or expanding the directory's children onto the work stack. The actual
    /// summary decision lands later in `completeAtomicDirectory`.
    private func handleTraversalSuccess(
        _ success: DirectoryTraversalSuccess,
        pendingAtomicScans: inout [AtomicDirectoryCandidate]
    ) throws {
        let item = success.item
        let itemKey = success.itemKey
        let meta = success.metadata
        let contents = success.contents
        let childEntries = contents.entries
        let leafBatch = success.leafBatch
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

        metrics.currentPath = item.path
        metrics.discoveredItems += childEntries.count
        metrics.enumeratedDirectoryCount += 1
        releasePendingDirectoryIfNeeded(for: item)
        // Counted on the worker during `makeDirectoryLeafBatch`; the
        // coordinator no longer re-walks the listing (which rebuilt each
        // child `URL` just to classify it).
        let childDirectoryCount = leafBatch.childDirectoryCount
        metrics.discoveredDirectoryCount += childDirectoryCount
        metrics.pendingDirectoryCount += childDirectoryCount
        metrics.recalculateProgress()
        maybeEmitProgress()

        // Check if this directory should be summarized as atomic (many small files)
        let minDepth = options.tuning.autoSummarizeMinDepthForSummarization ?? AtomicDirectoryThresholds.minDepthForSummarization
        let isNodeDependencyLayout = AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(at: item.url)
        let isKnownGeneratedDirectory = AtomicDirectorySummarizer.isKnownGeneratedDirectory(at: item.url)
        let canProbeForAutoSummary =
            item.depth >= minDepth ||
            (item.depth >= 1 && isNodeDependencyLayout) ||
            isKnownGeneratedDirectory
        let minFileCount = options.tuning.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
        if options.autoSummarizeDirectories, canProbeForAutoSummary,
           atomicDirectorySummarizer.isPooledSummaryProbeWorthwhile(
               childEntries: childEntries,
               minFileCount: minFileCount,
               isKnownGeneratedDirectory: isKnownGeneratedDirectory,
               isNodeDependencyLayout: isNodeDependencyLayout
           ) {
            // Defer probe + summary to a pooled task; the loop keeps draining.
            pendingAtomicScans.append(
                AtomicDirectoryCandidate(
                    item: item,
                    itemKey: itemKey,
                    metadata: meta,
                    contents: contents,
                    leafBatch: leafBatch,
                    childDirectoryCount: childDirectoryCount,
                    isNodeDependencyLayout: isNodeDependencyLayout
                )
            )
            return
        }

        try expandDirectory(
            item: item,
            itemKey: itemKey,
            metadata: meta,
            childEntries: childEntries,
            leafBatch: leafBatch
        )
    }

    /// Fans a directory's children onto the work stack and registers the
    /// directory for phase 2 assembly. Used both when auto-summary does not apply
    /// and when a deferred probe declines to summarize.
    private func expandDirectory(
        item: ScanWorkItem,
        itemKey: Int,
        metadata meta: NodeMetadata,
        childEntries: [DirectoryEntry],
        leafBatch: DirectoryLeafBatch
    ) throws {
        if childEntries.isEmpty {
            // Nothing below this directory: its whole weight is done.
            metrics.completedTraversalWeight += item.weight
            metrics.recalculateProgress()
        }

        // Weight-split denominator was summed on the worker (bit-identical: the
        // terms are 1 or `directoryChildWeightUnits`, exactly representable).
        let totalWeightUnits = leafBatch.totalWeightUnits

        let directLeafWeight = totalWeightUnits > 0
            ? item.weight / totalWeightUnits
            : 0
        foldDirectoryLeafBatch(leafBatch, weightPerEntry: directLeafWeight)

        // Enqueue only directories, packages, and unavailable entries. Plain
        // files and symlinks were already completed by the directory worker,
        // which also resolved each child's URL, mount-boundary flag, and weight
        // units — the coordinator only stamps the parent-relative fields. The
        // `item.weight * weightUnits / totalWeightUnits` association is
        // unchanged, so pushed weights stay bit-identical.
        for (offset, pending) in leafBatch.pendingChildWorkItems.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            workStack.append(
                ScanWorkItem(
                    url: pending.url,
                    path: pending.path,
                    metadata: pending.metadata,
                    localizedEnumerationError: pending.localizedEnumerationError,
                    isDirectoryHint: pending.isDirectoryHint,
                    blocksTraversalAtMountBoundary: pending.blocksTraversalAtMountBoundary,
                    parentKey: itemKey,
                    depth: item.depth + 1,
                    weight: item.weight * pending.weightUnits / totalWeightUnits
                )
            )
        }
        // Register this directory so phase 2 can assemble it.
        completedByKey[itemKey] = CompletedDirScan(
            node: nil,
            directLeafNodes: leafBatch.nodes,
            metadata: meta,
            url: item.url,
            isTraversable: true,
            depth: item.depth
        )
    }

    /// Folds a pooled package summary back onto the loop.
    private func completePackage(_ outcome: PackageSummaryOutcome) {
        foldLeafResult(
            outcome.leaf,
            item: outcome.item,
            itemKey: outcome.itemKey,
            metadata: outcome.metadata
        )
    }

    /// Folds a deferred auto-summary result back onto the loop: builds the atomic
    /// leaf when the probe summarized, or expands the directory when it declined.
    private func completeAtomicDirectory(_ outcome: AtomicDirectoryOutcome) throws {
        let candidate = outcome.candidate
        let item = candidate.item
        let meta = candidate.metadata
        let childEntries = candidate.contents.entries

        guard let summary = outcome.summary else {
            // Probe declined: expand the directory normally.
            try expandDirectory(
                item: item,
                itemKey: candidate.itemKey,
                metadata: meta,
                childEntries: childEntries,
                leafBatch: candidate.leafBatch
            )
            return
        }

        // Treat as atomic: create a leaf node with summary stats.
        let atomicNode = FileNodeRecord(
            id: item.path,
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
            isAutoSummarized: true,
            cloudOnlyLogicalSize: summary.cloudOnlyLogicalSize
        )
        hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
        minimumAllocatedSizeByNodeID[atomicNode.id] = meta.allocatedSize
        // The summarized children will never be enqueued: count them as
        // completed and release their frontier claims.
        metrics.completedItems += childEntries.count
        metrics.discoveredDirectoryCount = max(
            metrics.discoveredDirectoryCount - candidate.childDirectoryCount,
            0
        )
        metrics.pendingDirectoryCount = max(
            metrics.pendingDirectoryCount - candidate.childDirectoryCount,
            0
        )
        applyLeafMetrics(atomicNode, weight: item.weight)
        summaryPool?.acknowledgeProgress(
            jobIDs: summary.progressJobIDs,
            foldedInto: metrics
        )
        if !summary.warnings.isEmpty {
            warnings.append(contentsOf: summary.warnings)
            for warning in summary.warnings {
                continuation.yield(.warning(warning))
            }
        }
        maybeEmitProgress()

        completedByKey[candidate.itemKey] = CompletedDirScan(
            node: atomicNode,
            metadata: meta,
            url: item.url,
            isTraversable: false,
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
            id: item.path,
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
            if let scanStart = firstPartialReference {
                firstPartialReference = nil
                ScanTiming.record("scan.firstPartial", scanStart.duration(to: .now))
            }
            continuation.yield(.partial(partialStore))
        }
        lastPartialEmission = ContinuousClock.now
        let buildDuration = lastPartialEmission - buildStart
        partialEmissionInterval = max(.milliseconds(300), buildDuration * 10)
    }

    // MARK: - Phase 2: Assembly

    /// Phase 2: hand the completed phase-1 state to `ScanTreeAssembler`, which
    /// builds the contiguous store. Metrics, warnings, and progress emission
    /// stay here (scan-task confined) and are threaded in through callbacks.
    private func assembleTree() throws -> FileTreeStore {
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.finalizationFraction = 0
        metrics.recalculateProgress()
        continuation.yield(.progress(metrics))

        let callbacks = ScanTreeAssembler.Callbacks(
            cancellationCheck: { try Task.checkCancellation() },
            progress: { [self] fraction in
                metrics.finalizationFraction = fraction
                metrics.recalculateProgress()
                continuation.yield(.progress(metrics))
            },
            warning: { [self] warning in
                warnings.append(warning)
                continuation.yield(.warning(warning))
            },
            directoryFinalized: { [self] in
                metrics.completedItems = min(metrics.discoveredItems, metrics.completedItems + 1)
            }
        )

        // The coordinator no longer needs the completed batches; hand them to
        // the assembler (kept intact for a duplicate-id fallback rerun).
        let completed = completedByKey
        completedByKey = []
        // Collect the clone private sizes prefetched during traversal; the
        // deduplicator reads them first and falls back to a synchronous read for
        // any member not (yet) cached, so the result is identical either way.
        let prefetchedCloneSizes = clonePrivateSizePrefetcher?.drain() ?? [:]
        let cloneProvider: CloneDeduplicator.PrivateSizeProvider = { path in
            prefetchedCloneSizes[path] ?? CloneDeduplicator.systemPrivateSize(path: path)
        }
        let store = try ScanTreeAssembler.assemble(
            completedByKey: completed,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: nextKey,
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID,
            targetURL: target.url,
            diagnostics: diagnostics,
            clonePrivateSizeProvider: cloneProvider,
            callbacks: callbacks
        )

        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        maybeEmitProgress()

        return store
    }

    // MARK: - Leaf construction

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

    private static func isLikelyTraversableDirectory(entry: DirectoryEntry) -> Bool {
        // Same classification as the `metadata:url:isDirectoryHint:` overload,
        // but only builds `entry.url` (a lazy RFC3986 parse) in the rare
        // metadata-and-hint-absent fallback. Passing `entry.url` as an eager
        // argument rebuilt that URL for every child on the coordinator's hot
        // count/weight loops even though the metadata branch never reads it.
        if let metadata = entry.metadata {
            return metadata.isDirectory && !metadata.isSymbolicLink
        }
        if let isDirectoryHint = entry.isDirectoryHint {
            return isDirectoryHint
        }
        return entry.url.hasDirectoryPath
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
            node: FileNodeRecord.inaccessible(path: item.url.path, isDirectory: isDirectory),
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
        // Keep the pool heartbeat's base metrics fresh so its current-path
        // emissions (from workers and probes) never regress the loop's progress.
        summaryPool?.recordProgressBase(metrics)

        let visitedItems = metrics.filesVisited + metrics.directoriesVisited
        let now = Date()
        let elapsed = now.timeIntervalSince(emissionState.lastProgressEmission)
        let shouldEmit = visitedItems <= 2 || visitedItems.isMultiple(of: 1_000) || elapsed >= 0.15
        guard shouldEmit else { return }

        emissionState.lastProgressEmission = now
        if let summaryPool {
            summaryPool.publishProgressBase(metrics)
        } else {
            continuation.yield(.progress(metrics))
        }
    }

    private func shouldTraverseDirectory(
        metadata: NodeMetadata,
        isRoot: Bool = false,
        blocksTraversalAtMountBoundary: Bool = false
    ) -> Bool {
        guard metadata.isDirectory else { return false }
        guard !metadata.isSymbolicLink else { return false }
        guard isRoot || !blocksTraversalAtMountBoundary else { return false }
        guard metadata.isPackage else { return true }
        return options.treatPackagesAsDirectories
            || (isRoot && options.treatRootPackageAsDirectory)
    }

    /// A progress-only byte ceiling for volume scans (never a display
    /// figure): useful on non-APFS volumes where the used-capacity delta
    /// approximates what the traversal will visit. APFS container capacity
    /// is shared, so its free-space delta can overstate the scanned volume —
    /// those scans pace on traversal weight alone.
    private func estimatedTotalBytes(for target: ScanTarget, metadata: NodeMetadata) -> Int64 {
        guard target.kind == .volume,
              let volumeUsedCapacity = metadata.volumeUsedCapacity,
              shouldEstimateVolumeBytes(for: target.url) else {
            return 0
        }
        return max(volumeUsedCapacity, metadata.allocatedSize)
    }

    private func shouldEstimateVolumeBytes(for url: URL) -> Bool {
        guard let fileSystemType = volumeFileSystemTypeProvider(url) else {
            return false
        }
        let normalizedType = fileSystemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedType.isEmpty && normalizedType != "apfs"
    }
}
