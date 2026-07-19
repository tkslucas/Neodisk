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
        isSummaryProbeWorthwhile(
            directChildCount: childEntries.count,
            hasDirectoryChild: childEntries.contains {
                $0.metadata?.isDirectory ?? $0.url.hasDirectoryPath
            },
            minFileCount: minFileCount,
            isKnownGeneratedDirectory: isKnownGeneratedDirectory,
            isNodeDependencyLayout: isNodeDependencyLayout
        )
    }

    /// The candidate gate above expressed over just the direct-child counts the
    /// decision reads — no `DirectoryEntry` array. The incremental relist calls
    /// this with a directory's freshly-read direct children: if a membership
    /// change makes a directory newly eligible for a summary probe (or no longer
    /// eligible), the relist re-walks it so the summarize/expand decision matches
    /// a full scan exactly, instead of splicing a directory the traversal would
    /// have collapsed. Fires only for directories dense enough to summarize, so
    /// the re-walk is a rare, bounded fallback.
    nonisolated func isSummaryProbeWorthwhile(
        directChildCount: Int,
        hasDirectoryChild: Bool,
        minFileCount: Int,
        isKnownGeneratedDirectory: Bool,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        guard directChildCount > 0 else { return false }
        if directChildCount >= minFileCount { return true }
        if isKnownGeneratedDirectory { return true }
        if isNodeDependencyLayout { return true }
        // Sparse parents traverse cheaply; only dense ones warrant a probe.
        guard hasDirectoryChild else { return false }
        let minimumImmediateEntries = max(1, min(minFileCount, minFileCount / 10))
        return directChildCount >= minimumImmediateEntries
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
        makeFileNode(path: url.path, name: ScanTarget.displayName(for: url), metadata: metadata)
    }

    /// Hot-path leaf builder for enumerated children: the directory worker
    /// already holds the child's absolute path and name (from
    /// `DirectoryEntry`), so it constructs the record straight from strings
    /// without any per-file `url.path`/`lastPathComponent` derivation.
    func makeFileNode(path: String, name: String, metadata: NodeMetadata) -> FileNodeRecord {
        FileNodeRecord(
            id: path,
            path: path,
            name: name,
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
                minimumAllocatedSize: nil,
                progressJobIDs: []
            )
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: options.includeHiddenFiles,
            treatPackagesAsDirectories: true,
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
                minimumAllocatedSize: nil,
                progressJobIDs: []
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
            minimumAllocatedSize: metadata.allocatedSize,
            progressJobIDs: summary.progressJobIDs
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
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()

        // The whole recursive walk is one pool job: each directory level fans
        // across the shared workers, and nested packages and subdirectories fold
        // in as further work items rather than nested jobs. `metrics`/
        // `emissionState` are untouched here — the pool drives its own progress
        // heartbeat. Summaries only ever run inside a traversal, which binds the
        // pool in `ScanTraversal.run()`; there is no pool-less summary path.
        guard let summaryPool else {
            assertionFailure("AtomicDirectorySummarizer.summarize requires a summary pool")
            return nil
        }
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
}
