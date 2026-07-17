//
//  IncrementalScanService.swift
//  Neodisk
//
//  Full-scan wrapper that captures an FSEvents checkpoint per scan and, on
//  rescan, replays the journal since the baseline's checkpoint to re-scan
//  only the changed subtrees, splicing them atomically into the baseline
//  tree. Deliberately conservative: any ambiguity — provider failure,
//  planner doubt, a vanished subtree, a splice conflict — silently degrades
//  to the full scan the caller would have run anyway, and no partial
//  subtree result is ever published before the whole batch splice succeeds.
//

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
            historyProvider: DarwinFileSystemEventHistoryProvider(),
            isEnabled: ProcessInfo.processInfo.environment["NEODISK_INCREMENTAL"] != "0"
        )
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

    /// A plain full scan whose finished snapshot carries the FSEvents
    /// checkpoint captured before enumeration began — at scan START, so
    /// anything that changes mid-scan is replayed by the next rescan
    /// (over-scans slightly, never misses).
    public nonisolated func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        let checkpoint = target.kind == .cloud
            ? nil
            : try? historyProvider.currentCheckpoint(for: target)
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

    /// Rescans `target`, using the baseline (the previous complete snapshot
    /// of the same target, with its persisted checkpoint) to re-enumerate
    /// only the directories the FSEvents journal names. The provider closure
    /// lets the caller share one snapshot decode between display and this
    /// scan. Emits the same event stream a full scan would; callers cannot
    /// tell which path ran except by speed.
    public nonisolated func rescan(
        target: ScanTarget,
        options: ScanOptions,
        baselineProvider: @escaping @Sendable () async -> ScanSnapshot?
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            // Tracks the highest progress fraction the strip has shown this
            // session so any fallback full scan resumes forward from there —
            // the bar must never step backward within one scan strip.
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

        case .rescanSubtrees(let rootIDs):
            try await rescanAndSplice(
                rootIDs: rootIDs,
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

        case .relistRoot(let subtreeRootIDs):
            try await relistRootAndSplice(
                subtreeRootIDs: subtreeRootIDs,
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

    private nonisolated func rescanAndSplice(
        rootIDs: [String],
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
        // A plain subtree rescan is a relist with no membership edits and no
        // root-record refresh: every mapped root is an existing subtree the
        // splice replaces in place.
        var edits = RootRelistEdits()
        for rootID in rootIDs {
            guard baseline.treeStore.node(id: rootID) != nil else {
                return try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .subtreeVanished,
                    continuation: continuation,
                    floor: floor
                )
            }
            edits.subtreeScans.append(SubtreeScanRequest(role: .replace(baselineID: rootID), baselineID: rootID))
        }
        try await applyRelistEdits(
            edits,
            replacedRootPaths: rootIDs,
            isRootRelist: false,
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

    /// The scan-root membership relist (see `IncrementalRescanPlan.relistRoot`):
    /// one shallow readdir of the root, diffed against the baseline's direct
    /// children, turned into removals / insertions / file-record replacements
    /// that splice together with the deep `subtreeRootIDs` in a single pass.
    private nonisolated func relistRootAndSplice(
        subtreeRootIDs: [String],
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
        let rootID = baseline.treeStore.rootID

        // One readdir of the root — the real filesystem decides, events only
        // pointed us here. Any enumeration failure escalates to a full scan.
        let liveChildren: [ScanEngine.ShallowChild]
        do {
            liveChildren = try await engine.directChildren(
                of: target.url,
                options: options,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await forwardFullScan(
                target: target, options: options,
                reason: .rootRelistEnumerationFailed,
                continuation: continuation, floor: floor
            )
        }
        // A child we cannot classify (permission-denied direct child, missing
        // metadata) is rare at the root and ambiguous to diff; a full scan
        // reproduces it exactly, so escalate rather than guess.
        if liveChildren.contains(where: \.isUnavailable) {
            return try await forwardFullScan(
                target: target, options: options,
                reason: .rootRelistEnumerationFailed,
                continuation: continuation, floor: floor
            )
        }

        let baselineChildren = baseline.treeStore.children(of: rootID)
        var baselineChildByID = [String: FileNodeRecord](minimumCapacity: baselineChildren.count)
        for child in baselineChildren { baselineChildByID[child.id] = child }
        var liveChildByID = [String: ScanEngine.ShallowChild](minimumCapacity: liveChildren.count)
        for child in liveChildren { liveChildByID[child.url.path] = child }

        var edits = RootRelistEdits()

        // Deep subtree changes the same window mapped, minus any that fall under
        // a child the relist is about to remove.
        for id in subtreeRootIDs {
            guard baseline.treeStore.node(id: id) != nil else {
                return try await forwardFullScan(
                    target: target, options: options,
                    reason: .subtreeVanished,
                    continuation: continuation, floor: floor
                )
            }
            edits.subtreeScans.append(SubtreeScanRequest(role: .replace(baselineID: id), baselineID: id))
        }

        // Diff direct children.
        for (id, baselineChild) in baselineChildByID {
            guard let live = liveChildByID[id] else {
                // Child vanished: remove its whole subtree.
                edits.removals.append(id)
                continue
            }
            let baselineIsDirectory = baselineChild.isDirectory
            if baselineIsDirectory && live.isDirectoryLike {
                // Existing directory-like child: deep changes ride the normal
                // event→subtree mapping; the relist leaves it untouched.
                continue
            }
            if !baselineIsDirectory && !live.isDirectoryLike {
                // Existing leaf: replace its record only when it actually moved.
                if let leaf = live.leafRecord, !Self.leafRecordsMatch(baselineChild, leaf) {
                    edits.fileReplacements.append((id: id, store: FileTreeStore(root: leaf)))
                }
                continue
            }
            // Type changed (file↔directory): remove the old node, scan/insert
            // the new one — same as a full scan would produce.
            edits.removals.append(id)
            try appendInsertion(for: live, into: &edits)
        }
        for live in liveChildren where baselineChildByID[live.url.path] == nil {
            // Brand-new direct child.
            try appendInsertion(for: live, into: &edits)
        }

        // Reconcile deep subtree scans against removals: a subtree under a
        // removed child must not be scanned or spliced.
        if !edits.removals.isEmpty {
            let removedSet = Set(edits.removals)
            edits.subtreeScans.removeAll { request in
                guard case .replace(let baselineID) = request.role else { return false }
                return removedSet.contains(baselineID)
                    || baseline.treeStore.hasAncestor(in: removedSet, of: baselineID)
            }
        }

        // Refresh the root's own record (mtime moves whenever its membership
        // does); totals are re-derived by the splice. Skip when unchanged.
        var refreshedRoot: FileNodeRecord?
        if let liveRootMeta = engine.rootDirectoryMetadata(of: target.url) {
            let baselineRoot = baseline.treeStore.root
            if liveRootMeta.lastModified != baselineRoot.lastModified {
                refreshedRoot = baselineRoot.replacingLastModified(liveRootMeta.lastModified)
            }
        }
        edits.refreshedRootRecord = refreshedRoot

        // Nothing actually moved (the root event was spurious churn): advance
        // the checkpoint over the retained baseline, like `.noChanges`.
        if edits.isEmpty {
            log("root relist for \(target.id): no membership change; checkpoint advanced")
            var metrics = Self.metrics(from: baseline.aggregateStats)
            metrics.currentPath = target.url.path
            metrics.recalculateProgress(isComplete: true)
            floor.record(metrics.progressFraction)
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
                incrementalCheckpoint: cutoff
            )))
            return
        }

        let replacedRootPaths = edits.subtreeScans.compactMap { request -> String? in
            if case .replace(let baselineID) = request.role { return baselineID }
            return nil
        } + edits.removals + edits.fileReplacements.map(\.id)
        try await applyRelistEdits(
            edits,
            replacedRootPaths: replacedRootPaths,
            isRootRelist: true,
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

    /// Builds an insertion (a new direct child of the root): a scan request for
    /// a directory, or a prebuilt one-node store for a leaf.
    private nonisolated func appendInsertion(
        for live: ScanEngine.ShallowChild,
        into edits: inout RootRelistEdits
    ) throws {
        if live.isDirectoryLike {
            edits.subtreeScans.append(SubtreeScanRequest(
                role: .insertUnderRoot,
                baselineID: live.url.path
            ))
        } else if let leaf = live.leafRecord {
            edits.prebuiltInsertions.append(FileTreeStore(root: leaf))
        }
    }

    /// Scans every requested subtree, seeds the strip from the retained
    /// baseline totals, splices the whole batch of edits in one pass, and emits
    /// the finished snapshot. Shared by the plain subtree rescan and the root
    /// relist; `isRootRelist` selects the splice primitive and the log line.
    private nonisolated func applyRelistEdits(
        _ edits: RootRelistEdits,
        replacedRootPaths: [String],
        isRootRelist: Bool,
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

        // Counters seeded with the baseline totals minus everything leaving the
        // tree (rescanned subtrees, removed children, replaced files), so the
        // strip opens at what the previous scan already knows and grows as
        // sub-scans add their portions back — starting from zero would read as
        // a scan of almost nothing.
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
            case .insertUnderRoot:
                url = URL(filePath: request.baselineID, directoryHint: .isDirectory)
                name = ScanTarget.displayName(for: url)
                // A direct child of the scan root sits at depth 1.
                baseDepth = 1
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
        var insertions = edits.prebuiltInsertions
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
            case .insertUnderRoot:
                insertions.append(outcome.snapshot.treeStore)
            }
        }

        // Publish the merge phase so the strip isn't frozen at its rescan
        // ceiling while topology rebuilds and shared sizes rebalance. The
        // splice reports its own sub-phase boundaries into the band between the
        // ceiling and completion, so a multi-second merge on a huge baseline
        // shows honest forward motion instead of a static hold.
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
                if isRootRelist {
                    return try baseline.treeStore.applyingRootRelist(
                        refreshedRootRecord: edits.refreshedRootRecord,
                        removingChildren: edits.removals,
                        insertingChildren: insertions,
                        replacements: replacements,
                        spliceProgress: spliceProgress,
                        cancellationCheck: { try Task.checkCancellation() }
                    )
                }
                return try baseline.treeStore.replacingSubtrees(
                    replacements,
                    spliceProgress: spliceProgress,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            spliced = nil
        }
        guard let spliced else {
            return try await forwardFullScan(
                target: target, options: options,
                reason: isRootRelist ? .rootRelistFailed : .spliceFailed,
                continuation: continuation, floor: floor
            )
        }

        let warnings = ScanSnapshot.mergedWarningsPruningReplacedSubtrees(
            existing: baseline.scanWarnings,
            replacedRootPaths: replacedRootPaths,
            additional: newWarnings
        )
        if isRootRelist {
            log("relisted root for \(target.id): -\(edits.removals.count) +\(insertions.count) ~\(replacements.count) subtree(s)")
        } else {
            log("rescanned \(replacements.count) subtree(s) for \(target.id)")
        }

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

    /// Whether a baseline leaf record and a freshly-read one describe the same
    /// file, on the raw (pre-dedup) fields a fresh scan would compare. The
    /// splice's rebalance re-applies shared-size dedup, so `allocatedSize`
    /// (post-dedup on the baseline) is deliberately excluded.
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

    /// Streams a full scan into the rescan's event stream, remapping its
    /// progress fraction into the band above `floor` so the bar resumes forward
    /// from where the rescan left it instead of resetting to zero, and flags
    /// the metrics so the strip can say a full scan is running.
    private nonisolated func forwardFullScan(
        target: ScanTarget,
        options: ScanOptions,
        reason: IncrementalFullScanReason,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        floor: RescanProgressFloor
    ) async throws {
        log("full scan for \(target.id): \(reason.rawValue)")
        let resumeFrom = floor.current
        for try await event in scan(target: target, options: options) {
            switch event {
            case .progress(var metrics):
                // The engine's fraction spans [0, 1]; project it into the
                // remaining [floor, 1] band. Monotone because the engine's own
                // fraction is monotone and reaches 1 only at completion.
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
        guard target.kind != .cloud else { return .cloudTarget }
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
        // Baselines cached by older versions can still carry the retired
        // synthetic "System & Unattributed" reconcile node, which would go
        // stale across a splice; one full scan replaces them for good.
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

    /// Snapshot totals projected onto the strip's counters, so incremental
    /// progress speaks in whole-scan numbers rather than only the rescanned
    /// slice.
    private nonisolated static func metrics(from stats: ScanAggregateStats) -> ScanMetrics {
        var metrics = ScanMetrics()
        metrics.filesVisited = stats.fileCount
        metrics.directoriesVisited = stats.directoryCount
        metrics.bytesDiscovered = stats.totalAllocatedSize
        return metrics
    }

    /// Cap of the bar's rescan band; the last stretch is reserved for the
    /// splice, and completion snaps it to 1. Must not exceed the finalization
    /// band's floor, or the bar steps backward when assembly progress starts.
    private nonisolated static let rescanProgressCeiling = ScanMetrics.traversalSpan

    private nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("Neodisk IncrementalScanService: \(message)\n".utf8))
    }
}

/// How a scanned subtree's finished store folds into the splice.
enum SubtreeScanRole: Sendable {
    /// Replace the existing baseline subtree with this id.
    case replace(baselineID: String)
    /// Graft as a brand-new direct child of the scan root.
    case insertUnderRoot
}

/// One subtree the relist must re-enumerate. `baselineID` is the store id it
/// replaces, or the path of the new child it becomes.
struct SubtreeScanRequest {
    let role: SubtreeScanRole
    let baselineID: String
}

/// The full set of topology edits one root relist (or plain subtree rescan)
/// applies in a single splice: subtrees to scan, direct children to drop,
/// prebuilt leaf inserts/replacements, and the root's refreshed record.
struct RootRelistEdits {
    var subtreeScans: [SubtreeScanRequest] = []
    var removals: [String] = []
    var prebuiltInsertions: [FileTreeStore] = []
    var fileReplacements: [(id: String, store: FileTreeStore)] = []
    var refreshedRootRecord: FileNodeRecord?

    var isEmpty: Bool {
        subtreeScans.isEmpty && removals.isEmpty && prebuiltInsertions.isEmpty
            && fileReplacements.isEmpty && refreshedRootRecord == nil
    }
}

/// The highest progress fraction the strip has shown this rescan session.
/// A fallback full scan reads it to resume forward from where the incremental
/// path left the bar, so the fraction never steps backward. Thread-safe: the
/// subtree scans update it concurrently.
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
