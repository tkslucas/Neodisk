import Foundation

nonisolated struct AtomicDirectorySummarizer: Sendable {
    let metadataLoader: ScanMetadataLoader
    let diagnostics: ScanDiagnosticsContext?
    /// Mirrors ScanEngine's flag: getattrlistbulk walks with the FileManager
    /// path as fallback. Injected-provider tests keep this off.
    let bulkEnumerationEnabled: Bool
    /// When set, a whole recursive summary runs as one pool job instead of a fresh task group per call.
    var ownedDeviceIDs: Set<UInt64> = []
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

    /// Mirrors the cheap declines in `summaryIfNeeded`, so a directory that would expand never takes a summary
    /// slot or sits queued holding its child-entry array.
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

    /// The same gate over direct-child counts, for the relist: a membership change that flips eligibility
    /// forces a re-walk so the summarize decision matches a full scan.
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

    /// Returns a summary for dense small-file directories (node_modules, caches), nil to expand normally.
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
                rootEntries: childEntries,
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
        // Folds the already-enumerated entries with no extra I/O; only for flat directories.
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

    /// Hot path: builds straight from the strings the worker already holds, no `url.path` derivation.
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

    /// A non-expanded package becomes a summarized directory node whose totals come from walking it.
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
                cloudOnlyLogicalSize: summary.cloudOnlyLogicalSize,
                summarizedClones: SummarizedClones.make(members: summary.cloneMembers)
            ),
            warnings: summary.warnings,
            hardLinkClaims: summary.hardLinkClaims,
            minimumAllocatedSize: metadata.allocatedSize,
            progressJobIDs: summary.progressJobIDs
        )
    }

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

        // One pool job: levels fan across the shared workers and nested directories fold in as more work
        // items. Summaries only run inside a traversal, which binds the pool.
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
                cancellationCheck: cancellationCheck,
                ownedDeviceIDs: ownedDeviceIDs
            )
        )
    }
}
