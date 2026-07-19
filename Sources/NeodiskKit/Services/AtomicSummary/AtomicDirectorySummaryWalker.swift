//
//  AtomicDirectorySummaryWalker.swift
//  Neodisk
//

import Foundation

extension AtomicDirectorySummarizer {
    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    nonisolated func summarizeReusingImmediateChildren(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
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
        #if DEBUG
        let summaryStart = diagnostics?.start()
        #endif
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        updateAtomicAccessibility(rootMetadata.isReadable, in: state)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.summary.reused_entries",
                url: url,
                startedAt: summaryStart,
                itemCount: childEntries.count,
                detail: "files=\(state.partial.descendantFileCount)"
            )
        }
        #endif

        for (index, childEntry) in childEntries.enumerated() {
            try cancellationCheck()
            if index == 0 || index.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentPath: childEntry.path,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }

            guard !exclusionMatcher.excludes(
                childEntry.url,
                isDirectory: childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
            ) else {
                continue
            }

            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadataLoader.metadata(for: childEntry.url)
                } catch {
                    recordAtomicWarning(for: childEntry.url, error: error, in: state)
                    continue
                }
            }

            if childMetadata.isDirectory,
               childEntry.directoryMountStatus & MountBoundaryPolicy.mountPointFlag != 0 {
                continue
            }

            try await accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        return makeAtomicSummary(from: state)
    }

    nonisolated private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else { return }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        if metadata.isDirectory {
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = try await summarize(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories,
                    ownerNodeID: state.ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                ) {
                    merge(nestedSummary, into: state)
                }
            }
            return
        }

        accumulateAtomicFile(metadata, url: url, into: state)
    }

    nonisolated private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.partial.merge(summary)
    }

    nonisolated private func updateAtomicAccessibility(_ isReadable: Bool, in state: AtomicDirectorySummaryState) {
        state.partial.updateAccessibility(isReadable)
    }

    nonisolated private func recordAtomicWarning(
        for url: URL,
        error: Error,
        in state: AtomicDirectorySummaryState
    ) {
        state.partial.recordWarning(for: url, error: error)
    }

    nonisolated private func accumulateAtomicFile(_ metadata: NodeMetadata, url: URL, into state: AtomicDirectorySummaryState) {
        state.partial.accumulateFile(metadata, path: url.path, ownerNodeID: state.ownerNodeID)
    }

    nonisolated private func makeAtomicSummary(from state: AtomicDirectorySummaryState) -> AtomicDirectorySummary {
        state.partial.makeSummary()
    }

    nonisolated func emitProgressHeartbeat(
        currentPath: String,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        // Under a pool (probe running alongside pooled summaries), route through
        // the shared heartbeat so emissions carry the scan loop's fresh,
        // monotonic metrics instead of this task's stale local snapshot.
        if let summaryPool {
            summaryPool.emit(currentPath: currentPath)
            return
        }

        metrics.currentPath = currentPath
        let now = Date()
        guard now.timeIntervalSince(emissionState.lastProgressEmission) >= 0.15 else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }
}
