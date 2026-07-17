//
//  AtomicDirectoryParallelSummary.swift
//  Neodisk
//

import Foundation

nonisolated private final class AtomicSummaryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingItems: [AtomicSummaryWorkItem]
    private var activeItemCount = 0
    private var failure: Error?

    init(rootItem: AtomicSummaryWorkItem) {
        pendingItems = [rootItem]
    }

    func take() throws -> AtomicSummaryWorkItem? {
        condition.lock()
        defer { condition.unlock() }

        while pendingItems.isEmpty, activeItemCount > 0, failure == nil {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            try Task.checkCancellation()
        }

        if let failure {
            throw failure
        }

        guard let item = pendingItems.popLast() else {
            return nil
        }

        activeItemCount += 1
        return item
    }

    func enqueue(_ item: AtomicSummaryWorkItem) {
        condition.lock()
        pendingItems.append(item)
        condition.signal()
        condition.unlock()
    }

    func finishCurrentItem() {
        condition.lock()
        activeItemCount -= 1
        if pendingItems.isEmpty && activeItemCount == 0 {
            condition.broadcast()
        } else {
            condition.signal()
        }
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if failure == nil {
            failure = error
        }
        pendingItems.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

/// Lock-guarded wrapper over `AtomicDirectorySummaryPartial` for the non-pool
/// path, where several workers fold into one shared accumulator.
nonisolated private final class AtomicSummaryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = AtomicDirectorySummaryPartial()
    private var visitedItemCount = 0

    func recordVisitedItem() -> Int {
        lock.lock()
        visitedItemCount += 1
        let count = visitedItemCount
        lock.unlock()
        return count
    }

    func updateAccessibility(_ readable: Bool) {
        lock.lock()
        partial.updateAccessibility(readable)
        lock.unlock()
    }

    func recordWarning(for url: URL, error: Error) {
        lock.lock()
        partial.recordWarning(for: url, error: error)
        lock.unlock()
    }

    func accumulateFile(_ metadata: NodeMetadata, path: String, ownerNodeID: String) {
        lock.lock()
        partial.accumulateFile(metadata, path: path, ownerNodeID: ownerNodeID)
        lock.unlock()
    }

    func makeSummary() -> AtomicDirectorySummary {
        lock.lock()
        defer { lock.unlock() }
        return partial.makeSummary()
    }
}

nonisolated private final class AtomicSummaryProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: ScanMetrics
    private let continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    private var lastEmission = Date.distantPast
    private var hasEmitted = false

    init(
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) {
        self.metrics = metrics
        self.continuation = continuation
    }

    func emit(currentPath: String) {
        lock.lock()
        let now = Date()
        guard !hasEmitted || now.timeIntervalSince(lastEmission) >= 0.15 else {
            lock.unlock()
            return
        }

        metrics.currentPath = currentPath
        lastEmission = now
        hasEmitted = true
        continuation.yield(.progress(metrics))
        lock.unlock()
    }
}

extension AtomicDirectorySummarizer {
    /// Standalone parallel summary used when no scan-wide `AtomicDirectorySummaryPool`
    /// is available (injected-provider tests and any `summarize` call outside a
    /// traversal). Spins up its own bounded worker group over a shared queue.
    /// The traversal itself routes through the shared pool instead — see
    /// `AtomicDirectorySummarizer.summarize`.
    nonisolated static func summarizeInParallel(
        at url: URL,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        bulkEnumerationEnabled: Bool = false,
        metrics: ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> AtomicDirectorySummary? {
        try Task.checkCancellation()
        let progressReporter = AtomicSummaryProgressReporter(
            metrics: metrics,
            continuation: continuation
        )

        let accumulator = AtomicSummaryAccumulator()
        do {
            let rootValues = try url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
            accumulator.updateAccessibility(rootValues.isReadable ?? true)
        } catch {
            accumulator.recordWarning(for: url, error: error)
        }

        let queue = AtomicSummaryWorkQueue(
            rootItem: AtomicSummaryWorkItem(
                url: url,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                ownerNodeID: ownerNodeID
            )
        )
        let workerCount = max(1, workerLimit)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        guard let item = try queue.take() else { return }

                        do {
                            let sink = AtomicSummaryLevelSink(
                                onVisit: { childPath in
                                    let visitedItemCount = accumulator.recordVisitedItem()
                                    if visitedItemCount == 1 || visitedItemCount.isMultiple(of: 64) {
                                        progressReporter.emit(currentPath: childPath)
                                    }
                                },
                                onAccessibility: { accumulator.updateAccessibility($0) },
                                onWarning: { accumulator.recordWarning(for: $0, error: $1) },
                                onFile: { accumulator.accumulateFile($0, path: $1, ownerNodeID: item.ownerNodeID) },
                                onSubdirectory: { queue.enqueue($0) }
                            )
                            try Self.processDirectoryLevel(
                                item,
                                includeHiddenFiles: includeHiddenFiles,
                                exclusionMatcher: exclusionMatcher,
                                metadataLoader: metadataLoader,
                                bulkEnumerationEnabled: bulkEnumerationEnabled,
                                cancellationCheck: { try Task.checkCancellation() },
                                sink: sink
                            )
                            queue.finishCurrentItem()
                        } catch {
                            queue.fail(error)
                            queue.finishCurrentItem()
                            throw error
                        }
                    }
                }
            }

            do {
                try await group.waitForAll()
            } catch {
                queue.fail(error)
                group.cancelAll()
                throw error
            }
        }

        return accumulator.makeSummary()
    }

    /// Processes ONE directory level. Every child is reported to `sink`: files
    /// fold into the caller's partial/accumulator, subdirectories become new work
    /// items. Tries the getattrlistbulk reader first and, on any non-cancellation
    /// failure, restarts the level cleanly on the FileManager path — which owns
    /// the warning semantics for unreadable directories. Bulk reads a directory's
    /// full child list before folding any of it, so a fallback never double-counts.
    nonisolated static func processDirectoryLevel(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        bulkEnumerationEnabled: Bool,
        cancellationCheck: CancellationCheck,
        sink: AtomicSummaryLevelSink
    ) throws {
        try cancellationCheck()

        if bulkEnumerationEnabled {
            do {
                try processDirectoryLevelUsingBulkReader(
                    item,
                    includeHiddenFiles: includeHiddenFiles,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    sink: sink
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch is AtomicSummaryJobCancelled {
                throw AtomicSummaryJobCancelled()
            } catch {
                // Fall through to the FileManager path, which owns the
                // warning semantics for unreadable directories.
            }
        }

        try processDirectoryLevelUsingFoundation(
            item,
            includeHiddenFiles: includeHiddenFiles,
            exclusionMatcher: exclusionMatcher,
            metadataLoader: metadataLoader,
            cancellationCheck: cancellationCheck,
            sink: sink
        )
    }

    /// getattrlistbulk twin of the FileManager loop below: names and
    /// metadata arrive together, so there is no per-child resourceValues call.
    private nonisolated static func processDirectoryLevelUsingBulkReader(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        sink: AtomicSummaryLevelSink
    ) throws {
        let bulkChildren = try BulkDirectoryReader.children(
            ofDirectory: item.url,
            category: .summary,
            cancellationCheck: cancellationCheck
        )
        let normalizedParentPath = item.url.standardizedFileURL.path
        // `item.url.path` (not standardized) so claim keys / recursion identity
        // match the rest of the tree; child path is `basePath + "/" + name`.
        let basePath = item.url.path

        for child in bulkChildren {
            try cancellationCheck()
            if !includeHiddenFiles && child.isHidden { continue }

            let childPath = basePath == "/" ? "/" + child.name : basePath + "/" + child.name
            sink.onVisit(childPath)

            guard let childMetadata = child.metadata else {
                if let entryErrno = child.entryErrno {
                    sink.onWarning(
                        URL(filePath: childPath),
                        NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(entryErrno),
                            userInfo: [NSURLErrorKey: URL(filePath: childPath)]
                        )
                    )
                }
                continue
            }
            guard !exclusionMatcher.excludes(
                normalizedParentPath: normalizedParentPath,
                childName: child.name,
                isDirectory: childMetadata.isDirectory
            ) else {
                continue
            }

            sink.onAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                sink.onFile(childMetadata, childPath)
                continue
            }

            guard child.directoryMountStatus & MountBoundaryPolicy.mountPointFlag == 0 else {
                continue
            }

            sink.onSubdirectory(
                AtomicSummaryWorkItem(
                    url: URL(filePath: childPath, directoryHint: .isDirectory),
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }

    private nonisolated static func processDirectoryLevelUsingFoundation(
        _ item: AtomicSummaryWorkItem,
        includeHiddenFiles: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck,
        sink: AtomicSummaryLevelSink
    ) throws {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let childURLs: [URL]
        do {
            let enumerationResult = try ScanEngine.enumeratedDirectoryContents(
                url: item.url,
                keys: ScanMetadataLoader.atomicSummaryResourceKeys,
                options: options,
                cancellationCheck: cancellationCheck,
                makeEnumerator: { url, keys, options in
                    FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: keys,
                        options: options,
                        errorHandler: { childURL, error in
                            sink.onWarning(childURL, error)
                            return true
                        }
                    )
                }
            )
            childURLs = enumerationResult.urls
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            sink.onWarning(item.url, error)
            return
        }

        for childURL in childURLs {
            try cancellationCheck()
            sink.onVisit(childURL.path)

            let hintedIsDirectory = childURL.hasDirectoryPath
            guard !exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) else {
                continue
            }

            let childMetadata: NodeMetadata
            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
                childMetadata = metadataLoader.metadata(for: childURL, prefetchedResourceValues: values)
            } catch {
                sink.onWarning(childURL, error)
                continue
            }

            guard !exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) else {
                continue
            }

            sink.onAccessibility(childMetadata.isReadable)

            guard childMetadata.isDirectory else {
                sink.onFile(childMetadata, childURL.path)
                continue
            }

            let isTraversablePackageSymlink = childMetadata.isSymbolicLink
                && childMetadata.isPackage
                && !item.treatPackagesAsDirectories
            guard !childMetadata.isSymbolicLink || isTraversablePackageSymlink else {
                continue
            }

            sink.onSubdirectory(
                AtomicSummaryWorkItem(
                    url: childURL,
                    treatPackagesAsDirectories: childMetadata.isPackage ? true : item.treatPackagesAsDirectories,
                    ownerNodeID: item.ownerNodeID
                )
            )
        }
    }
}
