//
//  ScanEngine+Enumeration.swift
//  Neodisk
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    struct PartialSubtreeTotals: Sendable {
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

    /// Every key's subtree totals so far, kept up to date as results land
    /// (each completion adds to its key and that key's ancestors, O(depth)),
    /// so a partial build reads a depth-limit folder's running totals instead
    /// of re-summing everything below it, and visits only the keys at the
    /// display depth or above.
    struct PartialTreeTotals {
        let maxDepth: Int
        private(set) var parentByKey: [Int32] = []
        private(set) var totalsByKey: [PartialSubtreeTotals] = []
        /// Keys at `maxDepth` or above, ascending (a child after its parent).
        private(set) var shallowKeys: [Int] = []

        init(maxDepth: Int = partialTreeMaxDepth) {
            self.maxDepth = maxDepth
        }

        /// Registers the next key, in key order.
        mutating func allocate(parentKey: Int, depth: Int) {
            let key = parentByKey.count
            parentByKey.append(Int32(parentKey))
            totalsByKey.append(PartialSubtreeTotals())
            if depth <= maxDepth {
                shallowKeys.append(key)
            }
        }

        mutating func add(_ totals: PartialSubtreeTotals, at key: Int) {
            var current = key
            while current >= 0 {
                totalsByKey[current].add(totals)
                current = Int(parentByKey[current])
            }
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
        maxDepth: Int = partialTreeMaxDepth,
        runningTotals: PartialTreeTotals? = nil
    ) -> FileTreeStore? {
        guard nextKey > 0, !completedByKey.isEmpty else { return nil }
        if let runningTotals {
            return assemblePartialTree(
                completedByKey: completedByKey,
                childrenKeysByKey: childrenKeysByKey,
                nextKey: nextKey,
                runningTotals: runningTotals
            )
        }

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
                        isAccessible: completed.metadata.isReadable
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

    /// `assemblePartialTree` over running totals: identical output, but it
    /// visits only `runningTotals.shallowKeys`, reads each depth-limit
    /// folder's totals instead of summing its subtree, and lays the records
    /// straight into contiguous storage instead of the validating
    /// dictionary-built store.
    private nonisolated static func assemblePartialTree(
        completedByKey: [CompletedDirScan?],
        childrenKeysByKey: [[Int]],
        nextKey: Int,
        runningTotals: PartialTreeTotals
    ) -> FileTreeStore? {
        let maxDepth = runningTotals.maxDepth
        let walkSince = ScanProfile.now()
        var recordByKey: [Int: FileNodeRecord] = [:]
        recordByKey.reserveCapacity(runningTotals.shallowKeys.count)
        // A materialized folder's children in display order: the record, and
        // its key when it is itself a key (leaves are -1).
        var childrenByKey: [Int: [(key: Int, node: FileNodeRecord)]] = [:]

        for key in runningTotals.shallowKeys.reversed() where key < nextKey {
            guard let completed = completedByKey[key] else { continue }

            if completed.isTraversable {
                if completed.depth >= maxDepth {
                    let totals = runningTotals.totalsByKey[key]
                    recordByKey[key] = FileNodeRecord(
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
                    var children = completed.directLeafNodes.map { (key: -1, node: $0) }
                    let childKeys = childrenKeysByKey[key]
                    if !childKeys.isEmpty {
                        children.reserveCapacity(children.count + childKeys.count)
                        for childKey in childKeys {
                            if let childNode = recordByKey[childKey] {
                                children.append((key: childKey, node: childNode))
                            }
                        }
                    }
                    children = uniqueAssemblyPairs(children)
                    if children.count > 1 {
                        children.sort { FileTreeStore.childDisplayOrder($0.node, $1.node) }
                    }
                    recordByKey[key] = FileNodeRecord.directory(
                        id: completed.url.path,
                        url: completed.url,
                        name: ScanTarget.displayName(for: completed.url),
                        children: children.map(\.node),
                        lastModified: completed.metadata.lastModified,
                        fileIdentity: completed.metadata.fileIdentity,
                        linkCount: completed.metadata.linkCount,
                        isPackage: completed.metadata.isPackage,
                        isAccessible: completed.metadata.isReadable
                    )
                    childrenByKey[key] = children
                }
            } else if let node = completed.node {
                recordByKey[key] = node
            }
        }
        ScanProfile.end(.partialWalk, since: walkSince)
        guard let root = recordByKey[0] else { return nil }

        // Preorder flatten: a node's children are pushed in reverse so they
        // pop, get their indices, and join the parent's slots in display order.
        let storeSince = ScanProfile.now()
        var nodes: [FileNodeRecord] = []
        var parentIndices: [Int32] = []
        var childIndices: [[Int32]] = []
        var aggregateStats = ScanTraversal.AggregateStatsAccumulator()
        var stack: [(key: Int, node: FileNodeRecord, parent: Int32)] = [(0, root, -1)]
        while let entry = stack.popLast() {
            let index = Int32(nodes.count)
            nodes.append(entry.node)
            parentIndices.append(entry.parent)
            childIndices.append([])
            if entry.parent >= 0 {
                childIndices[Int(entry.parent)].append(index)
            }
            let children = entry.key >= 0 ? childrenByKey[entry.key] ?? [] : []
            aggregateStats.include(entry.node, hasChildren: !children.isEmpty)
            for child in children.reversed() {
                stack.append((child.key, child.node, index))
            }
        }
        var childStarts: [Int32] = []
        childStarts.reserveCapacity(nodes.count + 1)
        var childSlots: [Int32] = []
        childSlots.reserveCapacity(max(nodes.count - 1, 0))
        for slots in childIndices {
            childStarts.append(Int32(childSlots.count))
            childSlots.append(contentsOf: slots)
        }
        childStarts.append(Int32(childSlots.count))
        guard let built = NodeIDIndex.building(from: nodes) else {
            // Duplicate ids across folders: the validating store sorts it out.
            var childrenByID: [String: [FileNodeRecord]] = [:]
            for (key, children) in childrenByKey {
                if let id = recordByKey[key]?.id { childrenByID[id] = children.map(\.node) }
            }
            return FileTreeStore(root: root, childrenByID: childrenByID)
        }
        let store = FileTreeStore(
            trustedStorage: TreeStorage(
                nodes: nodes,
                parentIndices: parentIndices,
                childStarts: childStarts,
                childSlots: childSlots,
                indexByID: built.index,
                nodeHashes: built.hashes
            ),
            rootID: root.id,
            aggregateStats: aggregateStats.makeStats(root: root)
        )
        ScanProfile.end(.partialStore, since: storeSince)
        ScanProfile.add(.partialNodes, count: nodes.count)
        return store
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
        listings: DirectoryListingCache? = nil,
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
                            listings: listings,
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
        listings: DirectoryListingCache? = nil,
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
        let normalizedParentPath = exclusionMatcher.scanPath(of: url)
        // Node-id base: child path is `childBasePath + "/" + name`, byte-identical
        // to `url.appending(path: name).path` without the per-entry URL work.
        // Uses `url.path` (not standardized) so ids match the compatibility path.
        let childBasePath = url.path
        func add(_ child: BulkDirectoryChild) {
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
        // A folder an auto-summary probe just read (and declined) is taken
        // from its listing instead of being read again.
        let enumeratedItemCount: Int
        if let listed = listings?.take(forDirectory: childBasePath) {
            for child in listed {
                add(child)
            }
            enumeratedItemCount = listed.count
        } else {
            enumeratedItemCount = try BulkDirectoryReader.readChildren(
                ofDirectory: url,
                using: context,
                cancellationCheck: cancellationCheck,
                onChild: add
            )
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
