//
//  ScanEngine+Enumeration.swift
//  Neodisk
//

import Darwin
import Dispatch
import Foundation

// Static directory-enumeration and partial/final tree-assembly helpers
// extracted from ScanEngine.swift purely to keep each file a manageable size.
// Every helper here is `static`, so none touches ScanEngine's instance state.
//
// `PartialSubtreeTotals` and the private helpers `uniqueNodesAfterDuplicateFound`,
// `contentsOfLocalizedEnumerationFailures`, and `shouldFilterStartupVolumeInternals`
// are used only by the methods moved here, so they move too and stay `private`
// (file-scoped to this file) without any access-level change.
extension ScanEngine {
    /// Rolled-up subtree numbers for partial-tree nodes below the emission
    /// depth — enough to aggregate sizes upward without materializing
    /// records, URLs, or display names for the deep majority of the tree.
    private struct PartialSubtreeTotals {
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        /// Contribution to the parent's descendant file count (1 for a
        /// regular file, 0 for symlinks/synthetic nodes, the rolled-up
        /// count for directories).
        var descendantFileCount = 0
        var isAccessible = true

        init() {}

        init(of node: FileNodeRecord) {
            allocatedSize = node.allocatedSize
            logicalSize = node.logicalSize
            if node.isDirectory {
                descendantFileCount = node.descendantFileCount
            } else {
                descendantFileCount = node.isSymbolicLink || node.isSynthetic ? 0 : 1
            }
            isAccessible = node.isAccessible
        }

        mutating func add(_ child: PartialSubtreeTotals) {
            allocatedSize = allocatedSize.addingClamped(child.allocatedSize)
            logicalSize = logicalSize.addingClamped(child.logicalSize)
            descendantFileCount += child.descendantFileCount
            isAccessible = isAccessible && child.isAccessible
        }
    }

    /// Assembles a best-effort tree from phase-1 state without consuming it.
    /// Mirrors phase-2 assembly, but tolerates missing children (not yet
    /// scanned), skips hard-link deduplication, and never throws. Directory
    /// sizes therefore reflect only what has been visited so far.
    ///
    /// Only nodes at `maxDepth` or above are materialized as records; the
    /// deep remainder contributes rolled-up totals to its ancestor at the
    /// depth limit, so emission cost no longer grows with the whole scanned
    /// tree.
    nonisolated static func assemblePartialTree(
        completedByKey: [CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        nextKey: Int,
        maxDepth: Int = partialTreeMaxDepth
    ) -> FileTreeStore? {
        guard nextKey > 0, !completedByKey.isEmpty else { return nil }

        // Children always have higher keys than their parents, so a reverse
        // pass resolves every child before its parent needs it. Dense
        // key-indexed arrays mirror the coordinator's phase-1 state.
        var resolvedNodeByKey = [FileNodeRecord?](repeating: nil, count: nextKey)
        var totalsByKey = [PartialSubtreeTotals?](repeating: nil, count: nextKey)
        var childrenByID: [String: [FileNodeRecord]] = [:]

        for key in (0..<nextKey).reversed() {
            guard let completed = completedByKey[key] else { continue }

            if completed.depth > maxDepth {
                // Below the emission depth: roll up numbers only.
                if completed.isTraversable {
                    var totals = PartialSubtreeTotals()
                    totals.isAccessible = completed.metadata.isReadable
                    for leaf in completed.directLeafNodes {
                        totals.add(PartialSubtreeTotals(of: leaf))
                    }
                    for childKey in childrenKeysByKey[key] {
                        if let childTotals = totalsByKey[childKey] {
                            totals.add(childTotals)
                        }
                    }
                    totalsByKey[key] = totals
                } else if let node = completed.node {
                    totalsByKey[key] = PartialSubtreeTotals(of: node)
                }
            } else if completed.isTraversable {
                if completed.depth == maxDepth {
                    // The aggregated remainder: a childless directory record
                    // carrying its subtree's running totals.
                    var totals = PartialSubtreeTotals()
                    totals.isAccessible = completed.metadata.isReadable
                    for leaf in completed.directLeafNodes {
                        totals.add(PartialSubtreeTotals(of: leaf))
                    }
                    for childKey in childrenKeysByKey[key] {
                        if let childTotals = totalsByKey[childKey] {
                            totals.add(childTotals)
                        }
                    }
                    resolvedNodeByKey[key] = FileNodeRecord(
                        id: completed.url.path,
                        url: completed.url,
                        name: ScanTarget.displayName(for: completed.url),
                        isDirectory: true,
                        isSymbolicLink: false,
                        allocatedSize: totals.allocatedSize,
                        logicalSize: totals.logicalSize,
                        descendantFileCount: totals.descendantFileCount,
                        lastModified: completed.metadata.lastModified,
                        fileIdentity: completed.metadata.fileIdentity,
                        linkCount: completed.metadata.linkCount,
                        isPackage: completed.metadata.isPackage,
                        isAccessible: completed.metadata.isReadable && totals.isAccessible,
                        isSelfAccessible: completed.metadata.isReadable,
                        isSynthetic: false,
                        isAutoSummarized: false
                    )
                } else {
                    var childNodes = completed.directLeafNodes
                    let childKeys = childrenKeysByKey[key]
                    if !childKeys.isEmpty {
                        childNodes.reserveCapacity(childNodes.count + childKeys.count)
                        for childKey in childKeys {
                            if let childNode = resolvedNodeByKey[childKey] {
                                childNodes.append(childNode)
                            }
                        }
                    }
                    let sortedChildren = FileTreeStore.sortedChildren(
                        uniqueNodesForAssembly(childNodes)
                    )
                    let assembled = FileNodeRecord.directory(
                        id: completed.url.path,
                        url: completed.url,
                        name: ScanTarget.displayName(for: completed.url),
                        children: sortedChildren,
                        lastModified: completed.metadata.lastModified,
                        fileIdentity: completed.metadata.fileIdentity,
                        linkCount: completed.metadata.linkCount,
                        isPackage: completed.metadata.isPackage,
                        isAccessible: completed.metadata.isReadable,
                        childrenAreSorted: true
                    )
                    resolvedNodeByKey[key] = assembled
                    childrenByID[assembled.id] = sortedChildren
                }
            } else if let node = completed.node {
                resolvedNodeByKey[key] = node
            }
        }

        guard let root = resolvedNodeByKey[0] else { return nil }
        return FileTreeStore(root: root, childrenByID: childrenByID)
    }

    nonisolated static func uniqueNodesForAssembly(_ nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        guard nodes.count > 1 else { return nodes }

        var seenIDs = Set<String>()
        seenIDs.reserveCapacity(nodes.count)
        for node in nodes {
            guard seenIDs.insert(node.id).inserted else {
                return uniqueNodesAfterDuplicateFound(nodes)
            }
        }

        return nodes
    }

    private nonisolated static func uniqueNodesAfterDuplicateFound(_ nodes: [FileNodeRecord]) -> [FileNodeRecord] {
        var seenIDs = Set<String>()
        var uniqueNodes: [FileNodeRecord] = []
        uniqueNodes.reserveCapacity(nodes.count)

        for node in nodes where seenIDs.insert(node.id).inserted {
            uniqueNodes.append(node)
        }

        return uniqueNodes
    }

    /// `uniqueNodesForAssembly` for phase-2 (key, node) pairs.
    nonisolated static func uniqueAssemblyPairs(
        _ pairs: [(key: Int, node: FileNodeRecord)]
    ) -> [(key: Int, node: FileNodeRecord)] {
        guard pairs.count > 1 else { return pairs }

        var seenIDs = Set<String>()
        seenIDs.reserveCapacity(pairs.count)
        for pair in pairs {
            guard seenIDs.insert(pair.node.id).inserted else {
                var uniquePairs: [(key: Int, node: FileNodeRecord)] = []
                uniquePairs.reserveCapacity(pairs.count)
                var seen = Set<String>()
                for candidate in pairs where seen.insert(candidate.node.id).inserted {
                    uniquePairs.append(candidate)
                }
                return uniquePairs
            }
        }

        return pairs
    }

    nonisolated static func directoryEntries(
        of url: URL,
        includeHiddenFiles: Bool,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        directoryContents: DirectoryContentsProvider,
        classificationWorkerLimit: Int,
        usesBulkEnumeration: Bool = false,
        directoryIOExecutor: DirectoryIOExecutor? = nil,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> DirectoryContentsScanResult {
        try cancellationCheck()

        if usesBulkEnumeration {
            do {
                if let directoryIOExecutor {
                    return try await directoryIOExecutor.run { context, ioCancellationCheck in
                        try bulkDirectoryEntries(
                            of: url,
                            includeHiddenFiles: includeHiddenFiles,
                            behavior: behavior,
                            exclusionMatcher: exclusionMatcher,
                            context: context,
                            cancellationCheck: ioCancellationCheck
                        )
                    }
                }
                return try bulkDirectoryEntries(
                    of: url,
                    includeHiddenFiles: includeHiddenFiles,
                    behavior: behavior,
                    exclusionMatcher: exclusionMatcher,
                    context: BulkDirectoryReader.Context(),
                    cancellationCheck: cancellationCheck
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through: the FileManager path owns error semantics
                // (root enumeration failures become warnings upstream) and
                // covers volumes where getattrlistbulk is unsupported.
            }
        }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let prefetchKeys = shouldFilterStartupVolumeInternals(under: url, behavior: behavior)
            ? nil
            : Array(resourceKeys)
        #if DEBUG
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let enumerationResult = try directoryContents(url, prefetchKeys, options, cancellationCheck)
        #if DEBUG
        let enumerationNanoseconds = DispatchTime.now().uptimeNanoseconds - enumerationStart
        #endif
        try cancellationCheck()

        #if DEBUG
        let classificationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        var entries = try await Self.classifiedDirectoryEntries(
            enumerationResult.urls,
            under: url,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: resourceKeys,
            metadataLoader: metadataLoader,
            workerLimit: classificationWorkerLimit,
            cancellationCheck: cancellationCheck
        )
        entries.append(contentsOf:
            contentsOfLocalizedEnumerationFailures(
                enumerationResult.localizedFailures,
                under: url,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher
            )
        )
        #if DEBUG
        let classificationNanoseconds = DispatchTime.now().uptimeNanoseconds - classificationStart
        #endif

        try cancellationCheck()
        #if DEBUG
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count,
            enumerationNanoseconds: enumerationNanoseconds,
            classificationNanoseconds: classificationNanoseconds
        )
        #else
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumerationResult.urls.count + enumerationResult.localizedFailures.count
        )
        #endif
    }

    /// Fast-path listing: one getattrlistbulk stream provides names and
    /// metadata together, so no per-child resourceValues (classification)
    /// stage is needed at all.
    nonisolated static func bulkDirectoryEntries(
        of url: URL,
        includeHiddenFiles: Bool,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        context: BulkDirectoryReader.Context,
        cancellationCheck: @escaping CancellationCheck
    ) throws -> DirectoryContentsScanResult {
        #if DEBUG
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        var entries: [DirectoryEntry] = []
        // Normalize the parent path once per directory. The per-child exclusion
        // and name gates then work on strings — `parent + "/" + name` — instead
        // of rebuilding and re-standardizing a URL for every entry, and the URL
        // itself is only constructed for entries that survive filtering.
        let normalizedParentPath = url.standardizedFileURL.path
        // Node-id base: child path is `childBasePath + "/" + name`, byte-identical
        // to `url.appending(path: name).path` without the per-entry URL work.
        // Uses `url.path` (not standardized) so ids match the compatibility path.
        let childBasePath = url.path
        let enumeratedItemCount = try BulkDirectoryReader.readChildren(
            ofDirectory: url,
            using: context,
            cancellationCheck: cancellationCheck
        ) { child in
            if !includeHiddenFiles && child.isHidden { return }
            guard includedChildName(child.name, underParentPath: normalizedParentPath, behavior: behavior) else { return }
            let childPath = ScanEngine.nodeChildPath(parentPath: childBasePath, childName: child.name)

            if let entryErrno = child.entryErrno {
                entries.append(DirectoryEntry(
                    path: childPath,
                    name: child.name,
                    metadata: nil,
                    localizedEnumerationError: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(entryErrno),
                        userInfo: [NSURLErrorKey: URL(filePath: childPath)]
                    ),
                    deviceID: child.deviceID,
                    directoryMountStatus: child.directoryMountStatus
                ))
                return
            }

            guard let metadata = child.metadata else { return }
            guard !exclusionMatcher.excludes(
                normalizedParentPath: normalizedParentPath,
                childName: child.name,
                isDirectory: metadata.isDirectory
            ) else { return }
            // The concatenated node id must stay byte-identical to the URL's
            // own path, or ids drift from the compatibility path and snapshots.
            assert(
                childPath == url.appending(
                    path: child.name,
                    directoryHint: metadata.isDirectory ? .isDirectory : .notDirectory
                ).path,
                "childPath \(childPath) diverged from appended URL path"
            )
            entries.append(DirectoryEntry(
                path: childPath,
                name: child.name,
                metadata: metadata,
                deviceID: child.deviceID,
                directoryMountStatus: child.directoryMountStatus
            ))
        }

        #if DEBUG
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumeratedItemCount,
            enumerationNanoseconds: DispatchTime.now().uptimeNanoseconds - enumerationStart,
            classificationNanoseconds: 0
        )
        #else
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: enumeratedItemCount
        )
        #endif
    }

    private nonisolated static func contentsOfLocalizedEnumerationFailures(
        _ failures: [DirectoryEnumerationFailure],
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher
    ) -> [DirectoryEntry] {
        failures.compactMap { failure in
            let isDirectoryHint = failure.isDirectoryHint ?? failure.url.hasDirectoryPath
            guard includedChildURL(failure.url, under: parentURL, behavior: behavior),
                  !exclusionMatcher.excludes(failure.url, isDirectory: isDirectoryHint) else {
                return nil
            }
            return DirectoryEntry(
                path: failure.url.path,
                name: failure.url.lastPathComponent,
                metadata: nil,
                localizedEnumerationError: failure.error,
                isDirectoryHint: isDirectoryHint
            )
        }
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        workerLimit: Int,
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> [DirectoryEntry] {
        guard workerLimit > 1,
              contents.count >= ScanConcurrencyPolicy.directoryClassificationParallelThreshold else {
            return try classifiedDirectoryEntries(
                contents,
                offset: 0,
                under: parentURL,
                behavior: behavior,
                exclusionMatcher: exclusionMatcher,
                resourceKeys: resourceKeys,
                metadataLoader: metadataLoader,
                cancellationCheck: cancellationCheck
            ).map(\.entry)
        }

        let workerCount = min(max(1, workerLimit), contents.count)
        let chunkSize = max(
            ScanConcurrencyPolicy.directoryClassificationParallelThreshold,
            (contents.count + workerCount - 1) / workerCount
        )
        var classifiedEntries: [(offset: Int, entry: DirectoryEntry)] = []
        classifiedEntries.reserveCapacity(contents.count)

        try await withThrowingTaskGroup(of: [(offset: Int, entry: DirectoryEntry)].self) { group in
            var chunkStart = 0
            while chunkStart < contents.count {
                let chunkEnd = min(chunkStart + chunkSize, contents.count)
                let chunk = Array(contents[chunkStart..<chunkEnd])
                let offset = chunkStart
                group.addTask {
                    try classifiedDirectoryEntries(
                        chunk,
                        offset: offset,
                        under: parentURL,
                        behavior: behavior,
                        exclusionMatcher: exclusionMatcher,
                        resourceKeys: resourceKeys,
                        metadataLoader: metadataLoader,
                        cancellationCheck: cancellationCheck
                    )
                }
                chunkStart = chunkEnd
            }

            for try await chunkEntries in group {
                classifiedEntries.append(contentsOf: chunkEntries)
            }
        }

        classifiedEntries.sort { $0.offset < $1.offset }
        return classifiedEntries.map(\.entry)
    }

    private nonisolated static func classifiedDirectoryEntries(
        _ contents: [URL],
        offset: Int,
        under parentURL: URL,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        resourceKeys: Set<URLResourceKey>,
        metadataLoader: ScanMetadataLoader,
        cancellationCheck: CancellationCheck
    ) throws -> [(offset: Int, entry: DirectoryEntry)] {
        var entries: [(offset: Int, entry: DirectoryEntry)] = []
        entries.reserveCapacity(contents.count)

        for (localOffset, childURL) in contents.enumerated() {
            if localOffset.isMultiple(of: 64) {
                try cancellationCheck()
            }
            guard includedChildURL(childURL, under: parentURL, behavior: behavior) else {
                continue
            }

            ScanSyscallTally.recordMetadataLoad()
            let childMetadata = try? metadataLoader.metadata(
                for: childURL,
                prefetchedResourceValues: childURL.resourceValues(forKeys: resourceKeys),
                captureDirectoryIdentity: true
            )
            guard !exclusionMatcher.excludes(
                childURL,
                isDirectory: childMetadata?.isDirectory ?? childURL.hasDirectoryPath
            ) else {
                continue
            }

            entries.append((offset + localOffset, DirectoryEntry(
                path: childURL.path,
                name: childURL.lastPathComponent,
                metadata: childMetadata,
                deviceID: childMetadata?.fileIdentity?.fileSystemDeviceID
            )))
        }

        try cancellationCheck()
        return entries
    }

    private nonisolated static func shouldFilterStartupVolumeInternals(under parentURL: URL, behavior: ScanBehavior) -> Bool {
        behavior.excludesStartupVolumeInternals && ["/", "/System"].contains(parentURL.path)
    }

    /// The absolute node-id path of a child given its parent's node-id base
    /// path. One definition for every bulk enumerator (traversal, atomic
    /// summary, and probe walks) so child ids stay byte-identical across them —
    /// a drift would split one node into two. Root's children are `/name`,
    /// everyone else's `parent/name`. Callers pass whichever base their id
    /// scheme uses (`url.path` for the traversal, the standardized path for the
    /// probe); the join is what must not vary.
    nonisolated static func nodeChildPath(parentPath: String, childName: String) -> String {
        parentPath == "/" ? "/" + childName : parentPath + "/" + childName
    }

    nonisolated static func includedChildURL(_ childURL: URL, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        includedChildName(childURL.lastPathComponent, under: parentURL, behavior: behavior)
    }

    nonisolated static func includedChildName(_ childName: String, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        includedChildName(childName, underParentPath: parentURL.path, behavior: behavior)
    }

    /// Enumeration-hot overload: the parent path is computed once per directory
    /// by the caller instead of `parentURL.path` per child.
    nonisolated static func includedChildName(_ childName: String, underParentPath parentPath: String, behavior: ScanBehavior) -> Bool {
        if parentPath == "/" && [".nofollow", ".resolve"].contains(childName) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentPath == "/" &&
            [".file", ".vol", "dev", "Volumes"].contains(childName) {
            return false
        }

        if behavior.excludesStartupVolumeInternals &&
            parentPath == "/System" &&
            childName == "Volumes" {
            return false
        }

        return true
    }
}
