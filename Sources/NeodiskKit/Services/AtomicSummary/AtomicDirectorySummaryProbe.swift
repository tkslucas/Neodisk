//
//  AtomicDirectorySummaryProbe.swift
//  Neodisk
//

import Foundation

extension AtomicDirectorySummarizer {
    private nonisolated static func directoryOnlyProbeLimit(minFileCount: Int) -> Int {
        min(max(64, minFileCount / 4), 512)
    }

    nonisolated static func isKnownGeneratedDirectory(at url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3 else { return false }

        return Array(components.suffix(3)) == ["Library", "Developer", "CoreSimulator"]
    }

    nonisolated static func isNodeDependencyLayoutDirectory(at url: URL) -> Bool {
        isNodeDependencyLayoutDirectory(
            childName: url.lastPathComponent,
            parentName: url.deletingLastPathComponent().lastPathComponent
        )
    }

    /// Name-based form for the bulk probe, which holds each child's name and
    /// its parent directory's name without building a per-child `URL`.
    nonisolated static func isNodeDependencyLayoutDirectory(childName name: String, parentName: String) -> Bool {
        if name == "node_modules" || name == ".pnpm" {
            return true
        }

        guard name.hasPrefix("@") else { return false }
        return parentName == "node_modules" || parentName == ".pnpm"
    }

    nonisolated func shouldRunDescendantAtomicProbe(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        if isNodeDependencyLayout {
            return true
        }

        guard childEntries.contains(where: { childEntry in
            childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
        }) else {
            return false
        }

        // Sparse parents are cheaper to traverse normally; dense descendants can still summarize themselves.
        let minimumImmediateEntries = max(1, min(minFileCount, minFileCount / 10))
        return childEntries.count >= minimumImmediateEntries
    }

    nonisolated func immediateChildrenSuggestAtomicDirectory(
        _ childEntries: [DirectoryEntry],
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        try cancellationCheck()
        let sampleSize = min(100, childEntries.count)
        let step = max(1, childEntries.count / sampleSize)
        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for index in stride(from: 0, to: childEntries.count, by: step).prefix(sampleSize) {
            try cancellationCheck()
            let childEntry = childEntries[index]
            guard let childMetadata = childEntry.metadata else {
                return false
            }

            if !childMetadata.isDirectory {
                sampleTotalSize += childMetadata.logicalSize
                sampleFileCount += 1
            }
        }

        guard sampleFileCount > 0 else { return false }
        return (sampleTotalSize / Int64(sampleFileCount)) <= maxAverageFileSize
    }

    /// Depth-first bulk-read probe with the same sampling budget and early
    /// exits as the FileManager variant below. Only reached when bulk
    /// enumeration is enabled; per-directory failures skip that directory,
    /// matching the FileManager errorHandler that always continues.
    private nonisolated func bulkDescendantAtomicProbeProfile(
        at url: URL,
        includeHiddenFiles: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeProfile {
        try cancellationCheck()
        #if DEBUG
        let probeStart = diagnostics?.start()
        #endif
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.probe.bulk",
                url: url,
                startedAt: probeStart,
                itemCount: visitedItems,
                detail: "files=\(profile.observedFileCount) dirs=\(profile.observedDirectoryCount) nodeDeps=\(profile.observedNodeDependencyLayout)"
            )
        }
        #endif

        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount)

        var directoryStack: [URL] = [url]
        while let directoryURL = directoryStack.popLast() {
            try cancellationCheck()
            let children: [BulkDirectoryChild]
            do {
                children = try BulkDirectoryReader.children(
                    ofDirectory: directoryURL,
                    category: .probe,
                    cancellationCheck: cancellationCheck
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            let normalizedDirectoryPath = directoryURL.standardizedFileURL.path
            let directoryName = directoryURL.lastPathComponent

            for child in children {
                try cancellationCheck()
                if !includeHiddenFiles && child.isHidden { continue }
                guard let childMetadata = child.metadata else { continue }

                visitedItems += 1
                if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                    let childPath = normalizedDirectoryPath == "/"
                        ? "/" + child.name
                        : normalizedDirectoryPath + "/" + child.name
                    emitProgressHeartbeat(
                        currentPath: childPath,
                        metrics: &metrics,
                        continuation: continuation,
                        emissionState: &emissionState
                    )
                }
                guard visitedItems <= maxVisitedItems else { return profile }

                guard !exclusionMatcher.excludes(
                    normalizedParentPath: normalizedDirectoryPath,
                    childName: child.name,
                    isDirectory: childMetadata.isDirectory
                ) else {
                    continue
                }

                if Self.isNodeDependencyLayoutDirectory(childName: child.name, parentName: directoryName) {
                    profile.observedNodeDependencyLayout = true
                }

                guard !childMetadata.isDirectory else {
                    profile.observedDirectoryCount += 1
                    if child.directoryMountStatus & MountBoundaryPolicy.mountPointFlag != 0 {
                        continue
                    }
                    if !isNodeDependencyLayout,
                       profile.observedFileCount == 0,
                       profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                        return profile
                    }
                    // Only directories need a URL — to recurse into them.
                    directoryStack.append(
                        directoryURL.appending(path: child.name, directoryHint: .isDirectory)
                    )
                    continue
                }
                guard !childMetadata.isSymbolicLink else { continue }

                profile.totalSampledLogicalSize += childMetadata.logicalSize
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return profile
                }
                if profile.observedFileCount >= minFileCount {
                    return profile
                }
            }
        }

        return profile
    }

    nonisolated func descendantAtomicProbeProfile(
        at url: URL,
        includeHiddenFiles: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeProfile {
        try cancellationCheck()

        if bulkEnumerationEnabled {
            return try bulkDescendantAtomicProbeProfile(
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
        }
        #if DEBUG
        let probeStart = diagnostics?.start()
        #endif
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.probe",
                url: url,
                startedAt: probeStart,
                itemCount: visitedItems,
                detail: "files=\(profile.observedFileCount) dirs=\(profile.observedDirectoryCount) nodeDeps=\(profile.observedNodeDependencyLayout)"
            )
        }
        #endif
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicProbeResourceKeys,
            options: enumeratorOptions,
            errorHandler: { _, _ in true }
        ) else {
            return profile
        }

        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount)

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentPath: childURL.path,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            guard visitedItems <= maxVisitedItems else { return profile }

            let hintedIsDirectory = childURL.hasDirectoryPath
            if exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicProbeResourceKeySet)
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                if exclusionMatcher.excludes(childURL, isDirectory: isDirectory) {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if Self.isNodeDependencyLayoutDirectory(at: childURL) {
                    profile.observedNodeDependencyLayout = true
                }

                guard !isDirectory else {
                    profile.observedDirectoryCount += 1
                    // Dense file caches reveal files quickly; directory-only trees should traverse normally.
                    if !isNodeDependencyLayout,
                       profile.observedFileCount == 0,
                       profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                        return profile
                    }
                    continue
                }
                guard !isSymbolicLink else { continue }

                profile.totalSampledLogicalSize += Int64(values.fileSize ?? 0)
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return profile
                }
                // Once minimum sample is large-file-biased, skip summary and keep full detail.
                if profile.observedFileCount >= minFileCount {
                    return profile
                }
            } catch {
                return profile
            }
        }

        return profile
    }
}
