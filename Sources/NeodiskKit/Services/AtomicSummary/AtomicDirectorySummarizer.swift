//
//  AtomicDirectorySummarizer.swift
//  Neodisk
//

import Foundation

nonisolated struct AtomicDirectorySummarizer: Sendable {
    let metadataLoader: ScanMetadataLoader
    let diagnostics: ScanDiagnosticsContext?
    /// Mirrors ScanEngine's flag: getattrlistbulk walks with the FileManager
    /// path as fallback. Injected-provider tests keep this off.
    let bulkEnumerationEnabled: Bool
    /// Scan-wide worker pool shared across all package/atomic summaries. When
    /// present, `summarize` routes the whole recursive walk through it as one
    /// job (fanning directory levels across the shared workers) instead of
    /// spinning a fresh per-call task group. `nil` outside a traversal.
    let summaryPool: AtomicDirectorySummaryPool?

    init(
        metadataLoader: ScanMetadataLoader,
        diagnostics: ScanDiagnosticsContext? = nil,
        bulkEnumerationEnabled: Bool = false,
        summaryPool: AtomicDirectorySummaryPool? = nil
    ) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
        self.bulkEnumerationEnabled = bulkEnumerationEnabled
        self.summaryPool = summaryPool
    }

    /// Returns a copy bound to `pool`, so the shared summarizer configured on
    /// `ScanEngine` can adopt each `ScanTraversal` run's own pool.
    func withSummaryPool(_ pool: AtomicDirectorySummaryPool) -> AtomicDirectorySummarizer {
        AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            diagnostics: diagnostics,
            bulkEnumerationEnabled: bulkEnumerationEnabled,
            summaryPool: pool
        )
    }

    /// Zero-I/O gate the scan loop runs before deferring a directory to a
    /// pooled probe/summary task. Mirrors exactly the cheap declines at the top
    /// of `summaryIfNeeded`, so a directory that would trivially expand never
    /// occupies a summary request slot or sits in the candidate queue retaining
    /// its full child-entry array.
    nonisolated func isPooledSummaryProbeWorthwhile(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isKnownGeneratedDirectory: Bool,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        guard !childEntries.isEmpty else { return false }
        if childEntries.count >= minFileCount { return true }
        if isKnownGeneratedDirectory { return true }
        return shouldRunDescendantAtomicProbe(
            childEntries: childEntries,
            minFileCount: minFileCount,
            isNodeDependencyLayout: isNodeDependencyLayout
        )
    }

    /// Determines if a directory should be treated as atomic (summarized without expansion).
    /// Returns a summary if the directory has many small files (like node_modules, caches).
    /// Returns nil if the directory should be expanded normally.
    ///
    /// Sampling uses metadata decoded from `contentsOfDirectory`'s prefetched resource values,
    /// so no additional per-file resource lookups are needed.
    func summaryIfNeeded(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        guard !childEntries.isEmpty else { return nil }

        let immediateCandidate: Bool
        if childEntries.count >= minFileCount {
            immediateCandidate = try immediateChildrenSuggestAtomicDirectory(
                childEntries,
                maxAverageFileSize: maxAverageFileSize,
                cancellationCheck: cancellationCheck
            )
        } else {
            immediateCandidate = false
        }

        let deepCandidate: Bool
        if immediateCandidate {
            deepCandidate = true
        } else if Self.isKnownGeneratedDirectory(at: url) {
            deepCandidate = true
        } else {
            guard shouldRunDescendantAtomicProbe(
                childEntries: childEntries,
                minFileCount: minFileCount,
                isNodeDependencyLayout: isNodeDependencyLayout
            ) else {
                return nil
            }
            let profile = try descendantAtomicProbeProfile(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                isNodeDependencyLayout: isNodeDependencyLayout,
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            deepCandidate = profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            )
        }

        guard deepCandidate else {
            return nil
        }

        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        // The reuse fast path folds the already-enumerated immediate entries —
        // zero additional directory I/O — and only applies to flat directories
        // (few subdirectories), where the fold is pure CPU over prefetched
        // metadata. Under a pool it runs on the request's group child task and
        // routes any nested-directory walks through the pool.
        let canReuseImmediateEntries = immediateCandidate
            && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            return try await summarizeReusingImmediateChildren(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: url.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else { return nil }
        return summary
    }

    // MARK: - Leaf construction

    func makeFileNode(url: URL, metadata: NodeMetadata) -> FileNodeRecord {
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
            isAutoSummarized: false,
            isDataless: metadata.isDataless,
            cloneInfo: metadata.cloneInfo
        )
    }

    /// Builds the node for a leaf item: a plain file/symlink node, or — for a
    /// non-expanded package — a summarized directory node whose totals come from
    /// walking the package (through the pool when one is bound).
    func makeLeafNode(
        url: URL,
        metadata: NodeMetadata,
        options: ScanOptions,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> LeafNodeResult {
        try cancellationCheck()
        guard metadata.isPackage, metadata.isDirectory, !options.treatPackagesAsDirectories else {
            let node = makeFileNode(url: url, metadata: metadata)
            return LeafNodeResult(
                node: node,
                warnings: [],
                hardLinkClaims: HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                minimumAllocatedSize: nil
            )
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: workerLimit,
            ownerNodeID: url.path,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) else {
            let node = makeFileNode(url: url, metadata: metadata)
            return LeafNodeResult(
                node: node,
                warnings: [],
                hardLinkClaims: HardLinkDeduplicator.claim(for: metadata, ownerNodeID: node.id, path: url.path).map { [$0] } ?? [],
                minimumAllocatedSize: nil
            )
        }

        return LeafNodeResult(
            node: FileNodeRecord(
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
                isAutoSummarized: false,
                cloudOnlyLogicalSize: summary.cloudOnlyLogicalSize
            ),
            warnings: summary.warnings,
            hardLinkClaims: summary.hardLinkClaims,
            minimumAllocatedSize: metadata.allocatedSize
        )
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    func summarize(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()

        // Inside a traversal the whole recursive walk is one pool job: each
        // directory level fans across the shared workers, and nested packages
        // and subdirectories fold in as further work items rather than nested
        // jobs. `metrics`/`emissionState` are untouched here — the pool drives
        // its own progress heartbeat.
        if let summaryPool {
            return try await summaryPool.summarize(
                AtomicSummaryPoolRequest(
                    url: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    ownerNodeID: ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    metadataLoader: metadataLoader,
                    bulkEnumerationEnabled: bulkEnumerationEnabled,
                    cancellationCheck: cancellationCheck
                )
            )
        }

        if workerLimit > 1 {
            #if DEBUG
            let summaryStart = diagnostics?.start()
            #endif
            let summary = try await Self.summarizeInParallel(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: ownerNodeID,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                bulkEnumerationEnabled: bulkEnumerationEnabled,
                metrics: metrics,
                continuation: continuation
            )
            #if DEBUG
            diagnostics?.record(
                operation: "atomic.summary.parallel",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount,
                detail: "workers=\(workerLimit)"
            )
            #endif
            return summary
        }

        return try await summarizeSerial(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            ownerNodeID: ownerNodeID,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        )
    }
}
