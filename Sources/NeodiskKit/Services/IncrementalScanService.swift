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
            let task = Task(priority: .userInitiated) {
                do {
                    let baseline = await baselineProvider()
                    try Task.checkCancellation()
                    try await self.performRescan(
                        target: target,
                        options: options,
                        baseline: baseline,
                        continuation: continuation
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
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        if let reason = eligibilityFailure(target: target, options: options, baseline: baseline) {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: reason,
                continuation: continuation
            )
        }
        guard let baseline, let since = baseline.incrementalCheckpoint else {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: .missingCheckpoint,
                continuation: continuation
            )
        }

        let startedAt = Date()
        let through: FSEventsCheckpoint
        let history: FileSystemEventHistory
        do {
            through = try historyProvider.currentCheckpoint(for: target)
            history = try await historyProvider.history(since: since, through: through, target: target)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FileSystemEventHistoryError {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: Self.reason(for: error),
                continuation: continuation
            )
        } catch {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: .historyUnavailable,
                continuation: continuation
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
        let plan = IncrementalRescanPlanner.plan(
            events: history.events,
            target: target,
            baseline: baseline.treeStore,
            options: options,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher
        )

        switch plan {
        case .fullScan(let reason):
            try await forwardFullScan(
                target: target,
                options: options,
                reason: reason,
                continuation: continuation
            )

        case .noChanges:
            log("no changes for \(target.id) (\(history.events.count) events); checkpoint advanced")
            var metrics = ScanMetrics()
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
                baseline: baseline,
                cutoff: through,
                startedAt: startedAt,
                continuation: continuation
            )
        }
    }

    private nonisolated func rescanAndSplice(
        rootIDs: [String],
        target: ScanTarget,
        options: ScanOptions,
        behavior: ScanEngine.ScanBehavior,
        baseline: ScanSnapshot,
        cutoff: FSEventsCheckpoint,
        startedAt: Date,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        var subOptions = options
        subOptions.exclusionRootPath = options.exclusionRootPath ?? target.url.path

        var replacements: [(id: String, store: FileTreeStore)] = []
        var newWarnings: [ScanWarning] = []
        /// Visit counters of the subtrees already finished, so the strip's
        /// totals grow monotonically instead of resetting per subtree.
        var completedCounters = ScanMetrics()

        for (index, rootID) in rootIDs.enumerated() {
            guard let node = baseline.treeStore.node(id: rootID) else {
                return try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .subtreeVanished,
                    continuation: continuation
                )
            }
            // Depth in the baseline tree, so depth-gated auto-summarization
            // fires exactly as the original full scan's traversal did.
            let baseDepth = baseline.treeStore.path(to: rootID).count - 1
            // Member init on purpose: ScanTarget(url:) re-normalizes and
            // resolves symlinks, which could shift the id off the baseline's.
            let subTarget = ScanTarget(
                id: rootID,
                url: node.url,
                displayName: node.name,
                kind: .folder
            )

            var finished: ScanSnapshot?
            do {
                for try await event in engine.scanSubtree(
                    target: subTarget,
                    options: subOptions,
                    behavior: behavior,
                    baseDepth: baseDepth
                ) {
                    switch event {
                    case .progress(let metrics):
                        continuation.yield(.progress(Self.renormalized(
                            metrics,
                            completedCounters: completedCounters,
                            completedSubtrees: index,
                            totalSubtrees: rootIDs.count
                        )))
                    case .warning(let warning):
                        continuation.yield(.warning(warning))
                    case .partial:
                        break
                    case .finished(let snapshot):
                        finished = snapshot
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .subtreeScanFailed,
                    continuation: continuation
                )
            }
            guard let finished else {
                return try await forwardFullScan(
                    target: target,
                    options: options,
                    reason: .subtreeScanFailed,
                    continuation: continuation
                )
            }
            replacements.append((id: rootID, store: finished.treeStore))
            newWarnings.append(contentsOf: finished.scanWarnings)
            completedCounters.filesVisited += finished.aggregateStats.fileCount
            completedCounters.directoriesVisited += finished.aggregateStats.directoryCount
            completedCounters.bytesDiscovered = completedCounters.bytesDiscovered
                .addingClamped(finished.aggregateStats.totalAllocatedSize)
        }

        let spliced: FileTreeStore?
        do {
            spliced = try baseline.treeStore.replacingSubtrees(
                replacements,
                cancellationCheck: { try Task.checkCancellation() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            spliced = nil
        }
        guard let spliced else {
            return try await forwardFullScan(
                target: target,
                options: options,
                reason: .spliceFailed,
                continuation: continuation
            )
        }

        let warnings = ScanSnapshot.mergedWarningsPruningReplacedSubtrees(
            existing: baseline.scanWarnings,
            replacedRootPaths: rootIDs,
            additional: newWarnings
        )
        log("rescanned \(rootIDs.count) subtree(s) for \(target.id)")

        var metrics = completedCounters
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        continuation.yield(.finished(ScanSnapshot(
            target: target,
            treeStore: spliced,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: warnings,
            aggregateStats: spliced.aggregateStats,
            isComplete: true,
            scanOptions: options,
            incrementalCheckpoint: cutoff
        )))
    }

    // MARK: - Fallback

    private nonisolated func forwardFullScan(
        target: ScanTarget,
        options: ScanOptions,
        reason: IncrementalFullScanReason,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        log("full scan for \(target.id): \(reason.rawValue)")
        for try await event in scan(target: target, options: options) {
            continuation.yield(event)
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
        // The synthetic "System & Unattributed" reconcile node (non-APFS
        // volumes) goes stale across a splice; those volumes take the full
        // scan for now.
        guard !baseline.treeStore.children(of: baseline.treeStore.rootID)
            .contains(where: \.isSynthetic) else {
            return .unattributedVolumeNode
        }
        // A replaced root (new folder mounted or restored at the same path)
        // invalidates every node identity below it.
        if let liveIdentity = try? metadataLoader.metadata(for: target.url).fileIdentity,
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
        default:
            return .historyUnavailable
        }
    }

    // MARK: - Progress

    /// One sub-scan's cumulative metrics mapped into the whole rescan's
    /// 0–0.95 band, on top of the counters from subtrees already finished.
    private nonisolated static func renormalized(
        _ metrics: ScanMetrics,
        completedCounters: ScanMetrics,
        completedSubtrees: Int,
        totalSubtrees: Int
    ) -> ScanMetrics {
        var combined = completedCounters
        combined.filesVisited += metrics.filesVisited
        combined.directoriesVisited += metrics.directoriesVisited
        combined.bytesDiscovered = combined.bytesDiscovered.addingClamped(metrics.bytesDiscovered)
        combined.currentPath = metrics.currentPath
        let subtreeFraction = min(max(metrics.progressFraction, 0), 1)
        combined.progressFraction = min(
            (Double(completedSubtrees) + subtreeFraction) / Double(max(totalSubtrees, 1)) * 0.95,
            0.95
        )
        return combined
    }

    private nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("Neodisk IncrementalScanService: \(message)\n".utf8))
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
