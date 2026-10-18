#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// One scan's traversal and assembly state. Non-`Sendable` and confined to the scan task; task-group
/// children capture only immutable `Sendable` copies and return results through the group.
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
    /// Non-zero only for incremental subtree rescans, so depth-gated behavior (auto-summarize thresholds)
    /// fires exactly as in the full scan that produced the baseline.
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
    /// Directories inside other apps' containers, read at most
    /// `ProtectedContainers.concurrentReadLimit` at a time beside `workStack`.
    private var protectedWorkStack: [ScanWorkItem] = []
    /// Indexed by dense key (0..<nextKey), cheaper than a hash map. A nil slot is allocated but not yet
    /// completed, only observable during partial emission.
    private var completedByKey: [CompletedDirScan?] = []
    /// Maps parent key → child keys, built during phase 1. Same dense-key
    /// array shape as `completedByKey`; a key with no children keeps `[]`.
    private var childrenKeysByKey: [[Int]] = []
    /// Running subtree totals for the live partial trees.
    private var partialTotals = ScanEngine.PartialTreeTotals()
    private var seenScannedNodeIDs = Set<String>()
    private var nextKey = 0
    // The first partial goes out once the root listing is in; afterwards the interval adapts so partial
    // builds stay under ~10% of scan time.
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
        // Sized to the nominal ceiling: the pool is fixed for the scan's life, and a scan started under thermal
        // pressure must be able to speed back up. The adaptive in-flight limit does the throttling.
        self.directoryIOExecutor = DirectoryIOExecutor(
            workerCount: concurrency.undegradedTraversalWorkerLimit + ProtectedContainers.concurrentReadLimit
        )
        self.metrics = metrics
        self.warnings = warnings
        self.emissionState = emissionState
    }

    // MARK: - Entry point

    /// Scans the target's directory iteratively (no recursion) and returns a
    /// fully assembled flat tree.
    func run() async throws -> FileTreeStore {
        // One shared pool owns every package/atomic summary, so a giant bundle fans across all workers instead
        // of stalling the loop. Torn down on both success and error paths.
        let pool = AtomicDirectorySummaryPool(
            workerLimit: atomicSummaryWorkerLimit,
            continuation: continuation
        )
        summaryPool = pool
        atomicDirectorySummarizer = atomicDirectorySummarizer.withSummaryPool(pool)
        pool.start()
        ScanSyscallTally.reset()
        ScanProfile.begin()

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
            atomicDirectorySummarizer.ownedDeviceIDs = ownedDeviceIDs
            metrics.discoveredItems = 1
            metrics.estimatedTotalBytes = estimatedTotalBytes(for: target, metadata: rootMetadata)
            metrics.currentPath = target.url.path
            metrics.recalculateProgress()
            // Seeds the pool heartbeat's base metrics; otherwise a root-leaf scan (package root) runs its whole
            // summary with the heartbeat dropping every emission.
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
            ScanProfile.emit()
            return store
        } catch {
            ScanProfile.emit()
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
        publishProgress()
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
                weight: 1,
                isInProtectedContainer: ProtectedContainers.contains(target.url.path)
            )
        ]

        // Sendable copies for child tasks, so they never capture the non-Sendable `self`.
        let options = self.options
        let behavior = self.behavior
        let exclusionMatcher = self.exclusionMatcher
        let cancellationCheck = self.cancellationCheck
        let scanMetadataLoader = metadataLoader
        let directoryContentsProvider = directoryContents
        let directoryResourceKeys = ScanMetadataLoader.scanResourceKeys
        let usesBulkEnumeration = bulkEnumerationEnabled
        let directoryIOExecutor = self.directoryIOExecutor
        let listings = summaryPool?.listings
        let continuation = self.continuation
        // Set once in `run()` before the group starts, so workers can resolve mount-boundary flags off the
        // coordinator from an immutable copy.
        let ownedDeviceIDs = self.ownedDeviceIDs

        let summarizer = self.atomicDirectorySummarizer
        let summaryWorkerLimit = self.atomicSummaryWorkerLimit
        // The pool bounds actual CPU; this only caps summaries in flight so probes and result plumbing don't
        // pile up.
        let summaryRequestLimit = max(1, summaryWorkerLimit * 2)
        let autoSummarizeMinFileCount = options.tuning.autoSummarizeMinFileCount ?? AtomicDirectoryThresholds.minFileCount
        let autoSummarizeMaxAverageFileSize = options.tuning.autoSummarizeMaxAverageFileSize ?? AtomicDirectoryThresholds.maxAverageFileSize

        try await withThrowingTaskGroup(of: ScanTaskOutcome.self) { group in
            var activeDirectoryTasks = 0
            var activeProtectedDirectoryTasks = 0
            // One counter for both package and atomic-directory summary tasks.
            var activeSummaryTasks = 0
            // Never summarized inline in the scheduling loop: awaiting a pool job there stops the group from
            // draining and freezes progress bookkeeping.
            var pendingPackageScans: [(item: ScanWorkItem, itemKey: Int, metadata: NodeMetadata)] = []
            var pendingAtomicScans: [AtomicDirectoryCandidate] = []

            var busySince = ScanProfile.now()
            while true {
                concurrency.refreshIfDue()
                while true {
                    let item: ScanWorkItem
                    if activeProtectedDirectoryTasks < ProtectedContainers.concurrentReadLimit,
                       let protectedItem = protectedWorkStack.popLast() {
                        item = protectedItem
                    } else if activeDirectoryTasks < concurrency.traversalWorkerLimit,
                              let mainItem = workStack.popLast() {
                        item = mainItem
                    } else {
                        break
                    }
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
                    partialTotals.allocate(parentKey: item.parentKey, depth: item.depth)

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
                        if item.isInProtectedContainer {
                            activeProtectedDirectoryTasks += 1
                        } else {
                            activeDirectoryTasks += 1
                        }
                        ScanProfile.add(.directoriesDispatched)
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
                                    listings: listings,
                                    cancellationCheck: cancellationCheck
                                )
                                var leafBatch = try ScanProfile.measure(.leafBatch) {
                                    try Self.makeDirectoryLeafBatch(
                                        from: contents.entries,
                                        ownedDeviceIDs: ownedDeviceIDs,
                                        summarizer: summarizer,
                                        cancellationCheck: cancellationCheck
                                    )
                                }
                                leafBatch.urlPathAndName = (
                                    taskItem.url.path,
                                    ScanTarget.displayName(for: taskItem.url)
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
                        let profileToken = ScanProfile.started(.packageTask, taskItem.path)
                        defer { ScanProfile.finish(profileToken) }
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
                        let profileToken = ScanProfile.started(.summaryTask, candidate.item.path)
                        defer { ScanProfile.finish(profileToken) }
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

                guard activeDirectoryTasks + activeProtectedDirectoryTasks + activeSummaryTasks > 0 else { break }
                ScanProfile.end(.coordinatorBusy, since: busySince)
                let waitSince = ScanProfile.now()
                guard let outcome = try await group.next() else { break }
                busySince = ScanProfile.now()
                ScanProfile.end(.coordinatorWait, since: waitSince)

                switch outcome {
                case .directory(.success(let success)):
                    if success.item.isInProtectedContainer {
                        activeProtectedDirectoryTasks -= 1
                    } else {
                        activeDirectoryTasks -= 1
                    }
                    try ScanProfile.measure(.handleDirectory) {
                        try handleTraversalSuccess(success, pendingAtomicScans: &pendingAtomicScans)
                    }
                case .directory(.failure(let failure)):
                    if failure.item.isInProtectedContainer {
                        activeProtectedDirectoryTasks -= 1
                    } else {
                        activeDirectoryTasks -= 1
                    }
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

    /// Builds leaf records on the directory worker that already owns the child metadata. Iterating in
    /// reverse keeps the duplicate rule: the last enumerated path wins.
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

            // Frontier and weight bookkeeping folded into this pass, accumulated over the whole listing
            // (duplicates included) to match the coordinator's former loops.
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
            if !node.isSymbolicLink {
                batch.fileCount += 1
            }
            batch.allocatedSize = batch.allocatedSize.addingClamped(node.allocatedSize)
            batch.leafTotals.add(ScanEngine.PartialSubtreeTotals(of: node))
            if let claim = HardLinkDeduplicator.claim(
                for: metadata,
                ownerNodeID: node.id,
                path: node.path
            ) {
                batch.hardLinkClaims.append(claim)
            }
        }

        // Push order is behavioral: `seenScannedNodeIDs` is first-seen-wins, so children must reach the work
        // stack in enumeration order.
        batch.nodes.reverse()
        batch.pendingChildWorkItems.reverse()
        batch.duplicateWarnings.reverse()
        // Presorted in parallel here: assembly's stable sort uses the same comparator, so presorted runs make it
        // near-linear without changing its result.
        batch.nodes.sort { lhs, rhs in
            lhs.allocatedSize == rhs.allocatedSize
                ? DisplayNameOrder.precedes(lhs.name, rhs.name)
                : lhs.allocatedSize > rhs.allocatedSize
        }
        return batch
    }

    /// Applies one directory worker's aggregate leaf accounting in O(1) loop
    /// interactions, then emits any exceptional duplicate warnings.
    private func foldDirectoryLeafBatch(
        _ batch: DirectoryLeafBatch,
        weightPerEntry: Double
    ) {
        hardLinkClaims.append(contentsOf: batch.hardLinkClaims)
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
        if let node = completedByKey[itemKey]?.node {
            partialTotals.add(ScanEngine.PartialSubtreeTotals(of: node), at: itemKey)
        }
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
        if let node = completedByKey[itemKey]?.node {
            partialTotals.add(ScanEngine.PartialSubtreeTotals(of: node), at: itemKey)
        }
    }

    /// Frontier bookkeeping, then either defers the auto-summary probe to a pooled task or expands the
    /// children onto the work stack. The summary decision lands in `completeAtomicDirectory`.
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
        // Counted on the worker, so the coordinator doesn't re-walk the listing rebuilding each child `URL`.
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

    /// Used both when auto-summary does not apply and when a deferred probe declines to summarize.
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

        // Only directories, packages and unavailable entries are enqueued; the worker already completed files
        // and symlinks. The weight formula is unchanged so pushed weights stay bit-identical.
        let childrenAreInProtectedContainer = ProtectedContainers.containsChildren(ofDirectory: item.path)
        for (offset, pending) in leafBatch.pendingChildWorkItems.enumerated() {
            if offset.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let child = ScanWorkItem(
                url: pending.url,
                path: pending.path,
                metadata: pending.metadata,
                localizedEnumerationError: pending.localizedEnumerationError,
                isDirectoryHint: pending.isDirectoryHint,
                blocksTraversalAtMountBoundary: pending.blocksTraversalAtMountBoundary,
                parentKey: itemKey,
                depth: item.depth + 1,
                weight: item.weight * pending.weightUnits / totalWeightUnits,
                isInProtectedContainer: childrenAreInProtectedContainer
            )
            // A container folder goes on the container lane too, which is served first: otherwise its reads start
            // late in depth-first order and one five-second stall becomes the scan's tail.
            if childrenAreInProtectedContainer
                || ProtectedContainers.containsChildren(ofDirectory: pending.path) {
                protectedWorkStack.append(child)
            } else {
                workStack.append(child)
            }
        }
        // Register this directory so phase 2 can assemble it.
        completedByKey[itemKey] = CompletedDirScan(
            node: nil,
            directLeafNodes: leafBatch.nodes,
            directLeafNodesAreSorted: true,
            directLeafTotals: leafBatch.leafTotals,
            metadata: meta,
            url: item.url,
            pathAndName: leafBatch.urlPathAndName,
            isTraversable: true,
            depth: item.depth
        )
        var leafTotals = leafBatch.leafTotals
        leafTotals.isAccessible = leafTotals.isAccessible && meta.isReadable
        partialTotals.add(leafTotals, at: itemKey)
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
            cloudOnlyLogicalSize: summary.cloudOnlyLogicalSize,
            summarizedClones: SummarizedClones.make(members: summary.cloneMembers)
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
        if let node = completedByKey[candidate.itemKey]?.node {
            partialTotals.add(ScanEngine.PartialSubtreeTotals(of: node), at: candidate.itemKey)
        }
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
        if let node = completedByKey[itemKey]?.node {
            partialTotals.add(ScanEngine.PartialSubtreeTotals(of: node), at: itemKey)
        }
    }

    private func maybeEmitPartialTree() {
        guard ContinuousClock.now - lastPartialEmission >= partialEmissionInterval else { return }
        let buildStart = ContinuousClock.now
        if let partialStore = ScanEngine.assemblePartialTree(
            completedByKey: completedByKey,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: nextKey,
            runningTotals: partialTotals
        ) {
            if let scanStart = firstPartialReference {
                firstPartialReference = nil
                ScanTiming.record("scan.firstPartial", scanStart.duration(to: .now))
            }
            continuation.yield(.partial(partialStore))
        }
        lastPartialEmission = ContinuousClock.now
        let buildDuration = lastPartialEmission - buildStart
        ScanProfile.add(.partialBuild, nanoseconds: UInt64(buildDuration.components.attoseconds / 1_000_000_000)
            + UInt64(buildDuration.components.seconds) * 1_000_000_000)
        partialEmissionInterval = max(.milliseconds(300), buildDuration * 10)
    }

    // MARK: - Phase 2: Assembly

    /// Phase 2: `ScanTreeAssembler` builds the store; metrics, warnings and progress stay scan-task
    /// confined and are passed in through callbacks.
    private func assembleTree() throws -> FileTreeStore {
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        metrics.finalizationFraction = 0
        metrics.recalculateProgress()
        publishProgress()

        let callbacks = ScanTreeAssembler.Callbacks(
            cancellationCheck: { try Task.checkCancellation() },
            progress: { [self] fraction in
                metrics.finalizationFraction = fraction
                metrics.recalculateProgress()
                publishProgress()
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
        let store = try ScanTreeAssembler.assemble(
            completedByKey: completed,
            childrenKeysByKey: childrenKeysByKey,
            nextKey: nextKey,
            hardLinkClaims: hardLinkClaims,
            minimumAllocatedSizeByNodeID: minimumAllocatedSizeByNodeID,
            targetURL: target.url,
            diagnostics: diagnostics,
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

    /// A subdirectory hides an unscanned subtree of unknown size, so it gets more progress weight than a file.
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
        // Builds `entry.url` (a lazy RFC3986 parse) only in the rare fallback; passing it eagerly rebuilt the
        // URL for every child on the coordinator's hot loops.
        if let metadata = entry.metadata {
            return metadata.isDirectory && !metadata.isSymbolicLink
        }
        if let isDirectoryHint = entry.isDirectoryHint {
            return isDirectoryHint
        }
        return entry.url.hasDirectoryPath
    }

    /// Uses the same classifier as discovery so the pending count stays balanced.
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
        if let node = completedByKey[itemKey]?.node {
            partialTotals.add(ScanEngine.PartialSubtreeTotals(of: node), at: itemKey)
        }
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
        publishProgress()
    }

    private func publishProgress() {
        ScanProfile.add(.progressPublish)
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

    /// Progress-only byte ceiling, never displayed. APFS container capacity is shared and can overstate the
    /// volume, so those scans pace on traversal weight alone.
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
