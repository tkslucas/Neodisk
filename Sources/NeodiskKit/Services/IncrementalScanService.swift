// Rescans replay the FSEvents journal since the baseline's checkpoint and splice only changed subtrees.
// Any doubt degrades to a full scan, and nothing partial is published before the whole splice succeeds.

import Foundation

public final class IncrementalScanService: Sendable {
    private let engine: ScanEngine
    private let historyProvider: any FileSystemEventHistoryProviding
    /// `NEODISK_INCREMENTAL=0` kill switch: every rescan degrades to a full
    /// scan, which also keeps benchmarking honest.
    private let isEnabled: Bool
    private let metadataLoader = ScanMetadataLoader(diagnostics: nil)

    public convenience init() {
        self.init(
            engine: ScanEngine(),
            historyProvider: Self.platformHistoryProvider(),
            isEnabled: ProcessInfo.processInfo.environment["NEODISK_INCREMENTAL"] != "0"
        )
    }

    /// FSEvents on macOS; elsewhere there is no journal, so every rescan is
    /// a full scan (`missingCheckpoint`).
    private static func platformHistoryProvider() -> any FileSystemEventHistoryProviding {
        #if canImport(CoreServices)
        DarwinFileSystemEventHistoryProvider()
        #else
        UnsupportedFileSystemEventHistoryProvider()
        #endif
    }

    init(
        engine: ScanEngine,
        historyProvider: any FileSystemEventHistoryProviding,
        isEnabled: Bool = true
    ) {
        self.engine = engine
        self.historyProvider = historyProvider
        self.isEnabled = isEnabled
    }

    // MARK: - Full scan (checkpoint capture)

    /// The checkpoint is captured at scan start, so mid-scan changes replay next time (over-scan, never miss).
    public nonisolated func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        let checkpoint = try? historyProvider.currentCheckpoint(for: target)
        let upstream = engine.scan(target: target, options: options)
        guard let checkpoint else { return upstream }

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    for try await event in upstream {
                        if case .finished(let snapshot) = event {
                            continuation.yield(.finished(snapshot.attaching(checkpoint: checkpoint)))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Incremental rescan

    /// The provider lets the caller share one snapshot decode between display and this scan. Emits the same
    /// events as a full scan; only the speed differs.
    public nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        baselineProvider: @escaping @Sendable () async -> ScanSnapshot?
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            // The bar must never step backward: a fallback full scan resumes forward from this.
            let floor = RescanProgressFloor()
            let task = Task(priority: .userInitiated) {
                do {
                    // Baseline decode and journal replay emit nothing on
                    // their own; without this the strip opens on a dead bar.
                    var preparing = ScanMetrics()
                    preparing.currentPath = target.url.path
                    preparing.isCheckingChanges = true
                    continuation.yield(.progress(preparing))
                    let baseline = await ScanTiming.measure("rescan.baseline") {
                        await baselineProvider()
                    }
                    try Task.checkCancellation()
                    try await self.performRescan(
                        target: target,
                        options: options,
                        baseline: baseline,
                        continuation: continuation,
                        floor: floor
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private nonisolated func performRescan(
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot?,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        floor: RescanProgressFloor
    ) async throws {
        if let reason = eligibilityFailure(target: target, options: options, baseline: baseline) {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: reason,
                continuation: continuation,
                floor: floor
            )
        }
        guard let baseline, let since = baseline.incrementalCheckpoint else {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: .missingCheckpoint,
                continuation: continuation,
                floor: floor
            )
        }

        let startedAt = Date()
        let through: FSEventsCheckpoint
        let history: FileSystemEventHistory
        do {
            through = try historyProvider.currentCheckpoint(for: target)
            history = try await ScanTiming.measure("rescan.replay") {
                try await historyProvider.history(since: since, through: through, target: target)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FileSystemEventHistoryError {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: Self.reason(for: error),
                continuation: continuation,
                floor: floor
            )
        } catch {
            DiagnosticLog.rescan.warning("change history unavailable for \(target.id): \(error)")
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: .historyUnavailable,
                continuation: continuation,
                floor: floor
            )
        }

        let behavior = ScanEngine.ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path,
            includeCloudStorage: options.includeCloudStorage,
            cloudStorageRootPath: options.cloudStorageRootPath,
            iCloudDriveRootPath: options.iCloudDriveRootPath
        )
        let plan = ScanTiming.measure("rescan.plan", detail: "events=\(history.events.count)") {
            IncrementalRescanPlanner.plan(
                events: history.events,
                target: target,
                baseline: baseline.treeStore,
                options: options,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher
            )
        }

        switch plan {
        case .fullScan(let reason):
            try await forwardFullScan(
                target: target,
                options: options,
                reason: reason,
                continuation: continuation,
                floor: floor
            )

        case .noChanges:
            log("no changes for \(target.id) (\(history.events.count) events); checkpoint advanced")
            var metrics = Self.metrics(from: baseline.aggregateStats)
            metrics.currentPath = target.url.path
            metrics.recalculateProgress(isComplete: true)
            continuation.yield(.progress(metrics))
            continuation.yield(.finished(ScanSnapshot(
                target: target,
                treeStore: baseline.treeStore,
                startedAt: startedAt,
                finishedAt: Date(),
                scanWarnings: baseline.scanWarnings,
                aggregateStats: baseline.aggregateStats,
                isComplete: true,
                scanOptions: options,
                incrementalCheckpoint: through
            )))

        case .relistDirectories(let dirIDs, let deepRescanRootIDs):
            try await relistDirectoriesAndSplice(
                dirIDs: dirIDs,
                deepRescanRootIDs: deepRescanRootIDs,
                target: target,
                options: options,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher,
                baseline: baseline,
                cutoff: through,
                startedAt: startedAt,
                continuation: continuation,
                floor: floor
            )
        }
    }

    /// Shallow-relists each directory the journal named and deep re-walks only what FSEvents forces: N
    /// scattered changes cost N readdirs instead of re-walking their high-mass ancestors.
    private nonisolated func relistDirectoriesAndSplice(
        dirIDs: [String],
        deepRescanRootIDs: [String],
        target: ScanTarget,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        baseline: ScanSnapshot,
        cutoff: FSEventsCheckpoint,
        startedAt: Date,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        floor: RescanProgressFloor
    ) async throws {
        let store = baseline.treeStore

        // Phase 1: read each named directory once. A vanished one promotes its parent (sibling events may be
        // lost too), up to the scan root; any other ambiguity escalates to a full scan.
        struct DirRelist: Sendable {
            let dirID: String
            let node: FileNodeRecord
            let liveChildren: [ScanEngine.ShallowChild]
            let ownMetadata: NodeMetadata?
        }
        enum RelistOutcome: Sendable {
            case relisted(DirRelist)
            /// Gone (or no longer a directory): re-read this parent id next round.
            case promoteParent(String)
            /// Not present in the baseline tree, or a vanished scan root — skip
            /// (root handled by the caller's escalation).
            case skip
            /// The scan root itself vanished — only a full scan is trustworthy.
            case rootVanished
            /// Deep re-walk just this directory, as a full scan would: without Full Disk Access, churn constantly
            /// names directories with unreadable children, and bailing degraded every rescan to a full traversal.
            case deepRewalk(String)
        }
        let scanEngineRef = self.engine
        let rootID = store.rootID
        var relists: [DirRelist] = []
        var forcedDeepRewalkIDs: [String] = []
        var pending = dirIDs
        var visited = Set(dirIDs)
        // Bounded by tree depth (each round strictly climbs toward the root).
        while !pending.isEmpty {
            let round = pending
            pending = []
            let outcomes: [RelistOutcome]
            do {
                outcomes = try await BoundedAsyncMap.run(
                    round,
                    limit: ScanConcurrencyPolicy.incrementalSubtreeWorkerLimit()
                ) { dirID -> RelistOutcome in
                    guard let node = store.node(id: dirID) else { return .skip }
                    let ownMetadata = scanEngineRef.rootDirectoryMetadata(of: node.url)
                    guard let ownMetadata, ownMetadata.isDirectory, !ownMetadata.isSymbolicLink else {
                        guard let parentID = store.parent(of: dirID)?.id, parentID != dirID else {
                            return .rootVanished
                        }
                        return .promoteParent(parentID)
                    }
                    do {
                        let liveChildren = try await scanEngineRef.directChildren(
                            of: node.url,
                            options: options,
                            behavior: behavior,
                            exclusionMatcher: exclusionMatcher
                        )
                        return .relisted(DirRelist(
                            dirID: dirID,
                            node: node,
                            liveChildren: liveChildren,
                            ownMetadata: ownMetadata
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .deepRewalk(dirID)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DiagnosticLog.rescan.warning("root relist failed for \(target.id): \(error)")
                return try await forwardFullScan(
                    target: target, options: options,
                    reason: .rootRelistEnumerationFailed,
                    continuation: continuation, floor: floor
                )
            }
            for outcome in outcomes {
                switch outcome {
                case .relisted(let relist):
                    relists.append(relist)
                case .promoteParent(let parentID):
                    if visited.insert(parentID).inserted { pending.append(parentID) }
                case .deepRewalk(let dirID):
                    // Re-walking the root subtree IS a full scan; take it directly.
                    guard dirID != rootID else {
                        return try await forwardFullScan(
                            target: target, options: options,
                            reason: .rootRelistEnumerationFailed,
                            continuation: continuation, floor: floor
                        )
                    }
                    forcedDeepRewalkIDs.append(dirID)
                case .skip:
                    continue
                case .rootVanished:
                    return try await forwardFullScan(
                        target: target, options: options,
                        reason: .rootRelistEnumerationFailed,
                        continuation: continuation, floor: floor
                    )
                }
            }
        }

        var edits = DirectoryRelistEdits()

        // Phase 2a: a membership change can flip the auto-summarize decision, so such a directory is deep
        // re-walked instead of shallow-spliced.
        struct ShallowRelist { let relist: DirRelist }
        var shallowRelists: [ShallowRelist] = []
        var runtimeDeepRootIDs: [String] = []
        for relist in relists {
            let depth = store.path(to: relist.dirID).count - 1
            let isSummaryCandidate = self.engine.isRelistSummaryCandidate(
                directoryURL: relist.node.url,
                depth: depth,
                directChildCount: relist.liveChildren.count,
                hasDirectoryChild: relist.liveChildren.contains(where: \.isDirectoryLike),
                options: options
            )
            let wasSummarized = store.node(id: relist.dirID)?.isAutoSummarized ?? false
            if isSummaryCandidate || wasSummarized {
                runtimeDeepRootIDs.append(relist.dirID)
            } else {
                shallowRelists.append(ShallowRelist(relist: relist))
            }
        }

        // Phase 2b: deep roots (FSEvents-forced, summary-eligible, unreadable) collapse to disjoint roots;
        // shallow relists under them are redundant.
        var deepRootIDs = deepRescanRootIDs
        deepRootIDs.append(contentsOf: runtimeDeepRootIDs)
        deepRootIDs.append(contentsOf: forcedDeepRewalkIDs)
        let collapsedDeepRootIDs = store.topLevelNodeIDs(from: deepRootIDs)
        let deepRootSet = Set(collapsedDeepRootIDs)
        for id in collapsedDeepRootIDs {
            guard store.node(id: id) != nil else {
                return try await forwardFullScan(
                    target: target, options: options,
                    reason: .subtreeVanished,
                    continuation: continuation, floor: floor
                )
            }
            edits.subtreeScans.append(SubtreeScanRequest(role: .replace(baselineID: id), baselineID: id))
        }
        // A vanished directory under a deep root is covered by its re-walk; drop it so it can't overlap the replace.
        if !deepRootSet.isEmpty {
            edits.removals.removeAll { store.isNodeOrDescendant($0, of: deepRootSet) }
        }

        // Phase 2c: diff each relisted directory against its baseline children. Existing child directories are
        // left alone (FSEvents names their own changes); a re-read clears a stale warning at exactly that path.
        var relistedDirectoryPaths: [String] = []
        // Warnings a full scan would emit for unreadable children encountered
        // during the shallow relists, folded into the finished snapshot.
        var inlineWarnings: [ScanWarning] = []
        for shallow in shallowRelists {
            let relist = shallow.relist
            let dirID = relist.dirID
            if deepRootSet.contains(dirID) || store.isNodeOrDescendant(dirID, of: deepRootSet) {
                continue
            }
            relistedDirectoryPaths.append(dirID)
            let baselineChildren = store.children(of: dirID)
            var baselineChildByID = [String: FileNodeRecord](minimumCapacity: baselineChildren.count)
            for child in baselineChildren { baselineChildByID[child.id] = child }
            var liveChildByID = [String: ScanEngine.ShallowChild](minimumCapacity: relist.liveChildren.count)
            for child in relist.liveChildren { liveChildByID[child.url.path] = child }

            for (id, baselineChild) in baselineChildByID {
                guard let live = liveChildByID[id] else {
                    edits.removals.append(id)
                    continue
                }
                // An unreadable child collapses to its childless inaccessible node and warning, as in a full scan.
                if live.isUnavailable {
                    if let node = live.leafRecord {
                        let changed = store.containsChildren(id: id)
                            || !Self.leafRecordsMatch(baselineChild, node)
                        if changed {
                            edits.fileReplacements.append((id: id, store: FileTreeStore(root: node)))
                        }
                    }
                    if let warning = live.warning { inlineWarnings.append(warning) }
                    continue
                }
                let baselineIsDirectory = baselineChild.isDirectory
                if baselineIsDirectory && live.isDirectoryLike {
                    continue
                }
                if !baselineIsDirectory && !live.isDirectoryLike {
                    if let leaf = live.leafRecord, !Self.leafRecordsMatch(baselineChild, leaf) {
                        edits.fileReplacements.append((id: id, store: FileTreeStore(root: leaf)))
                    }
                    continue
                }
                edits.removals.append(id)
                appendInsertion(for: live, parentID: dirID, into: &edits)
            }
            for live in relist.liveChildren where baselineChildByID[live.url.path] == nil {
                if live.isUnavailable {
                    if let node = live.leafRecord {
                        edits.prebuiltInsertions.append((parentID: dirID, store: FileTreeStore(root: node)))
                    }
                    if let warning = live.warning { inlineWarnings.append(warning) }
                    continue
                }
                appendInsertion(for: live, parentID: dirID, into: &edits)
            }

            // Refresh every own-field from the relist's metadata, not just mtime: a directory that became
            // accessible must lose its stale inaccessible flag. Totals are re-derived by the splice.
            if let meta = relist.ownMetadata,
               meta.lastModified != relist.node.lastModified
                || meta.fileIdentity != relist.node.fileIdentity
                || meta.linkCount != relist.node.linkCount
                || meta.isPackage != relist.node.isPackage
                || meta.isReadable != relist.node.isSelfAccessible {
                edits.recordOverrides[dirID] = relist.node.refreshingOwnMetadata(meta)
            }
        }

        // Phase 4: drop edits at or under a removed subtree; they'd splice onto a node that no longer exists.
        if !edits.removals.isEmpty {
            let collapsedRemovals = store.topLevelNodeIDs(from: edits.removals)
            let removedSet = Set(collapsedRemovals)
            edits.removals = collapsedRemovals
            edits.fileReplacements.removeAll { store.isNodeOrDescendant($0.id, of: removedSet) }
            edits.prebuiltInsertions.removeAll { store.isNodeOrDescendant($0.parentID, of: removedSet) }
            edits.recordOverrides = edits.recordOverrides.filter {
                !store.isNodeOrDescendant($0.key, of: removedSet)
            }
            edits.subtreeScans.removeAll { request in
                switch request.role {
                case .replace(let baselineID):
                    return store.isNodeOrDescendant(baselineID, of: removedSet)
                case .insertUnder(let parentID):
                    return store.isNodeOrDescendant(parentID, of: removedSet)
                }
            }
        }

        // Spurious churn: advance the checkpoint like `.noChanges`, unless a stale warning still needs pruning.
        let relistedPathSet = Set(relistedDirectoryPaths)
        let hasStaleWarningToPrune = baseline.scanWarnings.contains { relistedPathSet.contains($0.path) }
        if edits.isEmpty && !hasStaleWarningToPrune {
            log("relist for \(target.id): no change; checkpoint advanced")
            var metrics = Self.metrics(from: baseline.aggregateStats)
            metrics.currentPath = target.url.path
            metrics.recalculateProgress(isComplete: true)
            floor.record(metrics.progressFraction)
            continuation.yield(.progress(metrics))
            continuation.yield(.finished(ScanSnapshot(
                target: target,
                treeStore: store,
                startedAt: startedAt,
                finishedAt: Date(),
                scanWarnings: baseline.scanWarnings,
                aggregateStats: baseline.aggregateStats,
                isComplete: true,
                scanOptions: options,
                incrementalCheckpoint: cutoff
            )))
            return
        }

        // Subtrees leaving the baseline: subtract their old totals from the progress seed, prune their warnings.
        let replacedRootPaths = edits.subtreeScans.compactMap { request -> String? in
            if case .replace(let baselineID) = request.role { return baselineID }
            return nil
        } + edits.removals + edits.fileReplacements.map(\.id)
        try await applyRelistEdits(
            edits,
            replacedRootPaths: replacedRootPaths,
            relistedDirectoryPaths: relistedDirectoryPaths,
            inlineWarnings: inlineWarnings,
            target: target,
            options: options,
            behavior: behavior,
            baseline: baseline,
            cutoff: cutoff,
            startedAt: startedAt,
            continuation: continuation,
            floor: floor
        )
    }

    /// A scan request for a directory-like child, or a prebuilt one-node store for a leaf.
    private nonisolated func appendInsertion(
        for live: ScanEngine.ShallowChild,
        parentID: String,
        into edits: inout DirectoryRelistEdits
    ) {
        if live.isDirectoryLike {
            edits.subtreeScans.append(SubtreeScanRequest(
                role: .insertUnder(parentID: parentID),
                baselineID: live.url.path
            ))
        } else if let leaf = live.leafRecord {
            edits.prebuiltInsertions.append((parentID: parentID, store: FileTreeStore(root: leaf)))
        }
    }

    private nonisolated func applyRelistEdits(
        _ edits: DirectoryRelistEdits,
        replacedRootPaths: [String],
        relistedDirectoryPaths: [String],
        inlineWarnings: [ScanWarning],
        target: ScanTarget,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        baseline: ScanSnapshot,
        cutoff: FSEventsCheckpoint,
        startedAt: Date,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        floor: RescanProgressFloor
    ) async throws {
        var subOptions = options
        subOptions.exclusionRootPath = options.exclusionRootPath ?? target.url.path
        let subtreeWorkerLimit = ScanConcurrencyPolicy.incrementalSubtreeWorkerLimit()
        if subOptions.tuning.directoryTraversalWorkerLimit == nil {
            let fullScanLimit = ScanConcurrencyPolicy.directoryTraversalWorkerLimit(
                for: options,
                bulkEnumeration: true,
                sourceProfile: ScanSourceProfile.detect(for: target.url)
            )
            subOptions.tuning.directoryTraversalWorkerLimit = max(
                4,
                fullScanLimit / max(1, subtreeWorkerLimit)
            )
        }

        // Seeded with the baseline minus what leaves the tree; starting from zero would read as a scan of nothing.
        var completedCounters = Self.metrics(from: baseline.aggregateStats)
        for id in replacedRootPaths {
            guard let node = baseline.treeStore.node(id: id) else { continue }
            completedCounters.filesVisited = max(completedCounters.filesVisited - node.descendantFileCount, 0)
            completedCounters.bytesDiscovered = max(completedCounters.bytesDiscovered - node.allocatedSize, 0)
        }
        completedCounters.currentPath = target.url.path
        let retainedFraction: Double
        if baseline.aggregateStats.totalAllocatedSize > 0 {
            retainedFraction = min(
                Double(completedCounters.bytesDiscovered)
                    / Double(baseline.aggregateStats.totalAllocatedSize),
                Self.rescanProgressCeiling
            )
        } else {
            retainedFraction = 0
        }
        completedCounters.progressFraction = retainedFraction
        floor.record(retainedFraction)
        continuation.yield(.progress(completedCounters))

        // Turn each scan request into a scan target, tagging it with the splice
        // role so the finished stores land as replacements or insertions.
        struct ResolvedScanRequest: Sendable {
            let index: Int
            let role: SubtreeScanRole
            let target: ScanTarget
            let baseDepth: Int
        }
        var requests: [ResolvedScanRequest] = []
        requests.reserveCapacity(edits.subtreeScans.count)
        for request in edits.subtreeScans {
            let baseDepth: Int
            let url: URL
            let name: String
            switch request.role {
            case .replace(let baselineID):
                guard let node = baseline.treeStore.node(id: baselineID) else {
                    return try await forwardFullScan(
                        target: target, options: options,
                        reason: .subtreeVanished,
                        continuation: continuation, floor: floor
                    )
                }
                url = node.url
                name = node.name
                // Depth in the baseline tree, so depth-gated auto-summarization
                // fires exactly as the original full scan's traversal did.
                baseDepth = baseline.treeStore.path(to: baselineID).count - 1
            case .insertUnder(let parentID):
                url = URL(filePath: request.baselineID, directoryHint: .isDirectory)
                name = ScanTarget.displayName(for: url)
                // One below the parent directory's baseline depth, so a new
                // subtree summarizes exactly where a full scan's traversal would.
                baseDepth = baseline.treeStore.path(to: parentID).count
            }
            requests.append(ResolvedScanRequest(
                index: requests.count,
                role: request.role,
                // Member init on purpose: ScanTarget(url:) re-normalizes and
                // resolves symlinks, which could shift the id off the baseline's.
                target: ScanTarget(id: request.baselineID, url: url, displayName: name, kind: .folder),
                baseDepth: baseDepth
            ))
        }

        let progressAggregator = IncrementalRescanProgressAggregator(
            base: completedCounters,
            subtreeCount: requests.count,
            retainedFraction: retainedFraction,
            progressCeiling: Self.rescanProgressCeiling
        )
        let subtreeOptions = subOptions
        let scanEngine = self.engine
        struct ScanOutcome: Sendable {
            let index: Int
            let role: SubtreeScanRole
            let snapshot: ScanSnapshot
        }
        enum SubtreeScanError: Error { case missingFinishedSnapshot }
        let outcomes: [ScanOutcome]
        let subtreeScanStart = ContinuousClock.now
        do {
            outcomes = try await BoundedAsyncMap.run(requests, limit: subtreeWorkerLimit) { request in
                var finished: ScanSnapshot?
                for try await event in scanEngine.scanSubtree(
                    target: request.target,
                    options: subtreeOptions,
                    behavior: behavior,
                    baseDepth: request.baseDepth
                ) {
                    switch event {
                    case .progress(let metrics):
                        let combined = progressAggregator.update(index: request.index, metrics: metrics)
                        floor.record(combined.progressFraction)
                        continuation.yield(.progress(combined))
                    case .warning(let warning):
                        continuation.yield(.warning(warning))
                    case .partial:
                        break
                    case .finished(let snapshot):
                        finished = snapshot
                    }
                }
                guard let finished else { throw SubtreeScanError.missingFinishedSnapshot }
                return ScanOutcome(index: request.index, role: request.role, snapshot: finished)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticLog.rescan.warning("subtree scan failed for \(target.id): \(error)")
            return try await forwardFullScan(
                target: target, options: options,
                reason: .subtreeScanFailed,
                continuation: continuation, floor: floor
            )
        }
        ScanTiming.record(
            "rescan.subtrees",
            subtreeScanStart.duration(to: .now),
            detail: "roots=\(outcomes.count)"
        )

        var replacements = edits.fileReplacements
        var insertions = edits.prebuiltInsertions.map {
            FileTreeStore.SubtreeInsertion(parentID: $0.parentID, store: $0.store)
        }
        var newWarnings: [ScanWarning] = []
        for outcome in outcomes.sorted(by: { $0.index < $1.index }) {
            newWarnings.append(contentsOf: outcome.snapshot.scanWarnings)
            completedCounters.filesVisited += outcome.snapshot.aggregateStats.fileCount
            completedCounters.directoriesVisited += outcome.snapshot.aggregateStats.directoryCount
            completedCounters.bytesDiscovered = completedCounters.bytesDiscovered
                .addingClamped(outcome.snapshot.aggregateStats.totalAllocatedSize)
            switch outcome.role {
            case .replace(let baselineID):
                replacements.append((id: baselineID, store: outcome.snapshot.treeStore))
            case .insertUnder(let parentID):
                insertions.append(FileTreeStore.SubtreeInsertion(
                    parentID: parentID, store: outcome.snapshot.treeStore
                ))
            }
        }

        // The splice reports sub-phases between the ceiling and completion, so a long merge keeps moving.
        var spliceMetrics = completedCounters
        spliceMetrics.currentPath = target.url.path
        spliceMetrics.isFinalizing = true
        spliceMetrics.isMergingChanges = true
        spliceMetrics.recalculateProgress()
        floor.record(spliceMetrics.progressFraction)
        continuation.yield(.progress(spliceMetrics))

        let mergeBase = spliceMetrics
        let mergeBandStart = spliceMetrics.progressFraction
        let mergeBandEnd = 0.99
        let spliceProgress: (Double) -> Void = { fraction in
            var m = mergeBase
            m.progressFraction = max(
                m.progressFraction,
                mergeBandStart + (mergeBandEnd - mergeBandStart) * min(max(fraction, 0), 1)
            )
            floor.record(m.progressFraction)
            continuation.yield(.progress(m))
        }

        let spliced: FileTreeStore?
        do {
            spliced = try ScanTiming.measure(
                "rescan.splice",
                detail: "baselineNodes=\(baseline.treeStore.nodeCount)"
            ) {
                try baseline.treeStore.applyingDirectoryRelist(
                    recordOverrides: edits.recordOverrides,
                    removingSubtrees: edits.removals,
                    insertions: insertions,
                    replacements: replacements,
                    spliceProgress: spliceProgress,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticLog.rescan.warning("relist splice failed for \(target.id), rescanning in full: \(error)")
            spliced = nil
        }
        guard let spliced else {
            return try await forwardFullScan(
                target: target, options: options,
                reason: .spliceFailed,
                continuation: continuation, floor: floor
            )
        }

        let warnings = ScanSnapshot.mergedWarningsPruningReplacedSubtrees(
            existing: baseline.scanWarnings,
            replacedRootPaths: replacedRootPaths,
            prunedExactPaths: relistedDirectoryPaths,
            additional: newWarnings + inlineWarnings
        )
        log("relisted \(target.id): -\(edits.removals.count) +\(insertions.count) ~\(replacements.count)")

        // aggregateStats is lazy after a splice; this access is a full-tree
        // pass and deserves its own timing.
        let splicedStats = ScanTiming.measure("rescan.stats") { spliced.aggregateStats }
        var metrics = Self.metrics(from: splicedStats)
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        floor.record(metrics.progressFraction)
        continuation.yield(.progress(metrics))
        continuation.yield(.finished(ScanSnapshot(
            target: target,
            treeStore: spliced,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: warnings,
            aggregateStats: splicedStats,
            isComplete: true,
            scanOptions: options,
            incrementalCheckpoint: cutoff
        )))
    }

    /// Raw (pre-dedup) fields only: the splice re-applies shared-size dedup, so `allocatedSize` is excluded.
    private nonisolated static func leafRecordsMatch(_ baseline: FileNodeRecord, _ live: FileNodeRecord) -> Bool {
        baseline.isDirectory == live.isDirectory
            && baseline.isSymbolicLink == live.isSymbolicLink
            && baseline.unduplicatedAllocatedSize == live.unduplicatedAllocatedSize
            && baseline.logicalSize == live.logicalSize
            && baseline.lastModified == live.lastModified
            && baseline.fileIdentity == live.fileIdentity
            && baseline.linkCount == live.linkCount
            && baseline.isPackage == live.isPackage
            && baseline.isSelfAccessible == live.isSelfAccessible
            && baseline.cloneInfo == live.cloneInfo
    }

    // MARK: - Fallback

    /// Remaps the full scan's fraction above `floor` so the bar resumes forward instead of resetting.
    private nonisolated func forwardFullScan(
        target: ScanTarget,
        options: ScanOptions,
        reason: IncrementalFullScanReason,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        floor: RescanProgressFloor
    ) async throws {
        DiagnosticLog.rescan.notice("full scan for \(target.id): \(reason.rawValue)")
        let resumeFrom = floor.current
        for try await event in scan(target: target, options: options) {
            switch event {
            case .progress(var metrics):
                // Project [0, 1] onto [floor, 1]; monotone because the engine's fraction is.
                metrics.progressFraction = resumeFrom + (1 - resumeFrom) * metrics.progressFraction
                metrics.isFullScanFallback = true
                floor.record(metrics.progressFraction)
                continuation.yield(.progress(metrics))
            default:
                continuation.yield(event)
            }
        }
    }

    private nonisolated func eligibilityFailure(
        target: ScanTarget,
        options: ScanOptions,
        baseline: ScanSnapshot?
    ) -> IncrementalFullScanReason? {
        guard isEnabled else { return .incrementalDisabled }
        guard let baseline else { return .noBaseline }
        guard baseline.isComplete else { return .baselineIncomplete }
        guard baseline.source.isPersistable else { return .baselineNotPersistable }
        guard baseline.target.id == target.id, baseline.target.kind == target.kind else {
            return .targetMismatch
        }
        guard let baselineOptions = baseline.scanOptions,
              baselineOptions.shapeSignature == options.shapeSignature else {
            return .scanOptionsChanged
        }
        guard baseline.incrementalCheckpoint != nil else { return .missingCheckpoint }
        // Old cached baselines may carry the retired "System & Unattributed" node; one full scan replaces them.
        guard !baseline.treeStore.children(of: baseline.treeStore.rootID)
            .contains(where: \.isSynthetic) else {
            return .unattributedVolumeNode
        }
        // A replaced root (new folder mounted or restored at the same path)
        // invalidates every node identity below it.
        if let liveIdentity = try? metadataLoader.metadata(
            for: target.url,
            captureDirectoryIdentity: true
        ).fileIdentity,
           let baselineIdentity = baseline.root.fileIdentity,
           liveIdentity != baselineIdentity {
            return .targetMismatch
        }
        return nil
    }

    private nonisolated static func reason(for error: FileSystemEventHistoryError) -> IncrementalFullScanReason {
        switch error {
        case .volumeChanged, .eventIDRolledBack, .invalidCheckpointRange, .checkpointExpired, .osBuildChanged:
            return .checkpointInvalid
        case .eventBudgetExceeded:
            return .historyBudgetExceeded
        case .historyReplayTimedOut:
            return .historyReplayTimedOut
        default:
            return .historyUnavailable
        }
    }

    // MARK: - Progress

    /// So incremental progress speaks in whole-scan numbers, not only the rescanned slice.
    private nonisolated static func metrics(from stats: ScanAggregateStats) -> ScanMetrics {
        var metrics = ScanMetrics()
        metrics.filesVisited = stats.fileCount
        metrics.directoriesVisited = stats.directoryCount
        metrics.bytesDiscovered = stats.totalAllocatedSize
        return metrics
    }

    /// Must not exceed the finalization band's floor, or the bar steps backward when assembly starts.
    private nonisolated static let rescanProgressCeiling = ScanMetrics.traversalSpan

    private nonisolated func log(_ message: String) {
        DiagnosticLog.rescan.info(message)
    }
}

/// How a scanned subtree's finished store folds into the splice.
enum SubtreeScanRole: Sendable {
    /// A deep re-walk of a summarized subtree, or a directory whose type flipped in place.
    case replace(baselineID: String)
    /// Graft as a brand-new child of the surviving directory `parentID`.
    case insertUnder(parentID: String)
}

/// One subtree the relist must re-enumerate. `baselineID` is the store id it
/// replaces, or the path of the new child it becomes.
struct SubtreeScanRequest {
    let role: SubtreeScanRole
    let baselineID: String
}

/// Every topology edit one relist batch applies in a single splice; keyed by parent, so any depth.
struct DirectoryRelistEdits {
    var subtreeScans: [SubtreeScanRequest] = []
    var removals: [String] = []
    var prebuiltInsertions: [(parentID: String, store: FileTreeStore)] = []
    var fileReplacements: [(id: String, store: FileTreeStore)] = []
    var recordOverrides: [String: FileNodeRecord] = [:]

    var isEmpty: Bool {
        subtreeScans.isEmpty && removals.isEmpty && prebuiltInsertions.isEmpty
            && fileReplacements.isEmpty && recordOverrides.isEmpty
    }
}

/// Thread-safe: the subtree scans update it concurrently.
final class RescanProgressFloor: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func record(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        if fraction > value { value = fraction }
    }

    var current: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

extension ScanSnapshot {
    /// Same snapshot (identity preserved) carrying the checkpoint captured
    /// when its scan started.
    nonisolated func attaching(checkpoint: FSEventsCheckpoint) -> ScanSnapshot {
        ScanSnapshot(
            id: id,
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: scanWarnings,
            aggregateStats: aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions,
            source: source,
            incrementalCheckpoint: checkpoint
        )
    }
}
