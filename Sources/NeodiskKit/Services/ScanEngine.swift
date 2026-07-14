//
//  ScanEngine.swift
//  Neodisk
//

import Darwin
import Dispatch
import Foundation

/// A `Sendable` final class on purpose: the whole scan path is
/// `nonisolated` and every stored property is `let`, so there is no
/// actor-mutable state to protect. The type used to be an actor, which
/// implied isolation that wasn't there — and actor-executor serialization
/// once let a still-cancelling scan block a freshly started one (see
/// testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling).
public final class ScanEngine: Sendable {
    protocol DirectoryObjectEnumerating: AnyObject {
        func nextObject() -> Any?
    }

    enum ScanEngineError: LocalizedError {
        case missingRootNode

        var errorDescription: String? {
            switch self {
            case .missingRootNode:
                return "The scan could not assemble a root node."
            }
        }
    }

    struct ScanBehavior: Sendable {
        let excludesStartupVolumeInternals: Bool

        static let standard = ScanBehavior(excludesStartupVolumeInternals: false)
    }

    struct DirectoryEnumerationFailure: Sendable {
        let url: URL
        let error: Error
        let isDirectoryHint: Bool?

        init(url: URL, error: Error, isDirectoryHint: Bool? = nil) {
            self.url = url
            self.error = error
            self.isDirectoryHint = isDirectoryHint
        }
    }

    struct DirectoryEnumerationResult: Sendable {
        let urls: [URL]
        let localizedFailures: [DirectoryEnumerationFailure]

        init(urls: [URL], localizedFailures: [DirectoryEnumerationFailure] = []) {
            self.urls = urls
            self.localizedFailures = localizedFailures
        }
    }

    struct DirectoryContentsScanResult: Sendable {
        let entries: [DirectoryEntry]
        let enumeratedItemCount: Int
        #if DEBUG
        let enumerationNanoseconds: UInt64
        let classificationNanoseconds: UInt64
        #endif
    }

    /// A completed directory scan awaiting parent assembly.
    struct CompletedDirScan {
        let node: FileNodeRecord?     // Leaves carry a node; traversable dirs are resolved in phase 2.
        let metadata: NodeMetadata
        let url: URL
        let isTraversable: Bool     // True if this was a directory we intended to traverse.
        let depth: Int              // Levels below the scan root (root is 0).
    }

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

    typealias DirectoryContentsProvider = @Sendable (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions,
        @Sendable () throws -> Void
    ) throws -> DirectoryEnumerationResult

    typealias URLDirectoryContentsProvider = @Sendable (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions,
        @Sendable () throws -> Void
    ) throws -> [URL]

    typealias VolumeFileSystemTypeProvider = @Sendable (URL) -> String?

    private let directoryContents: DirectoryContentsProvider
    private let metadataLoader: ScanMetadataLoader
    private let atomicDirectorySummarizer: AtomicDirectorySummarizer
    private let volumeFileSystemTypeProvider: VolumeFileSystemTypeProvider
    private let diagnostics: ScanDiagnosticsContext?
    /// When true, directory listing goes through getattrlistbulk(2) with the
    /// FileManager path kept as a per-directory fallback. Only the real
    /// filesystem engine enables this — injected test providers must stay
    /// authoritative for the directories they fake.
    private let bulkEnumerationEnabled: Bool

    /// Creates a scanner with the default filesystem-backed enumeration.
    public convenience init() {
        self.init(
            enumeratedDirectoryContents: ScanEngine.defaultDirectoryContents,
            bulkEnumerationEnabled: ProcessInfo.processInfo.environment["NEODISK_SCAN_BULK"] != "0"
        )
    }

    init(
        enumeratedDirectoryContents: @escaping DirectoryContentsProvider = ScanEngine.defaultDirectoryContents,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType,
        bulkEnumerationEnabled: Bool = false
    ) {
        #if DEBUG
        let diagnostics = ScanDiagnostics.makeIfEnabled()
        #else
        let diagnostics: ScanDiagnosticsContext? = nil
        #endif
        let metadataLoader = ScanMetadataLoader(diagnostics: diagnostics)
        self.directoryContents = enumeratedDirectoryContents
        self.metadataLoader = metadataLoader
        self.atomicDirectorySummarizer = AtomicDirectorySummarizer(
            metadataLoader: metadataLoader,
            diagnostics: diagnostics,
            bulkEnumerationEnabled: bulkEnumerationEnabled
        )
        self.volumeFileSystemTypeProvider = volumeFileSystemTypeProvider
        self.diagnostics = diagnostics
        self.bulkEnumerationEnabled = bulkEnumerationEnabled
    }

    convenience init(
        directoryContents: @escaping URLDirectoryContentsProvider,
        volumeFileSystemTypeProvider: @escaping VolumeFileSystemTypeProvider = ScanEngine.defaultVolumeFileSystemType
    ) {
        self.init(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            let urls = try directoryContents(url, keys, options, cancellationCheck)
            return DirectoryEnumerationResult(urls: urls)
        }, volumeFileSystemTypeProvider: volumeFileSystemTypeProvider)
    }

    private nonisolated static func defaultDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> DirectoryEnumerationResult {
        var rootEnumerationError: Error?
        var localizedFailures: [DirectoryEnumerationFailure] = []
        let rootPath = url.standardizedFileURL.path
        return try enumeratedDirectoryContents(
            url: url,
            keys: keys,
            options: options,
            cancellationCheck: cancellationCheck,
            makeEnumerator: { url, keys, options in
                FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: options,
                    errorHandler: { failedURL, error in
                        if failedURL.standardizedFileURL.path == rootPath {
                            rootEnumerationError = error
                            return false
                        }
                        localizedFailures.append(
                            DirectoryEnumerationFailure(
                                url: failedURL,
                                error: error,
                                isDirectoryHint: true
                            )
                        )
                        return true
                    }
                )
            },
            enumerationError: { rootEnumerationError },
            localizedEnumerationFailures: { localizedFailures }
        )
    }

    private nonisolated static func defaultVolumeFileSystemType(for url: URL) -> String? {
        var fileSystemStats = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &fileSystemStats)
        }
        guard result == 0 else { return nil }

        return withUnsafeBytes(of: fileSystemStats.f_fstypename) { rawBuffer -> String? in
            let buffer = rawBuffer.bindMemory(to: CChar.self)
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    nonisolated static func enumeratedDirectoryContents(
        url: URL,
        keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        cancellationCheck: @Sendable () throws -> Void,
        makeEnumerator: (
            URL,
            [URLResourceKey]?,
            FileManager.DirectoryEnumerationOptions
        ) -> (any DirectoryObjectEnumerating)?,
        enumerationError: () -> Error? = { nil },
        localizedEnumerationFailures: () -> [DirectoryEnumerationFailure] = { [] }
    ) throws -> DirectoryEnumerationResult {
        try cancellationCheck()
        guard let enumerator = makeEnumerator(url, keys, options) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSURLErrorKey: url]
            )
        }

        var contents: [URL] = []
        while let nextObject = enumerator.nextObject() {
            try cancellationCheck()
            if let enumerationError = enumerationError() {
                throw enumerationError
            }
            guard let childURL = nextObject as? URL else { continue }
            contents.append(childURL)
        }

        if let enumerationError = enumerationError() {
            throw enumerationError
        }
        try cancellationCheck()
        return DirectoryEnumerationResult(
            urls: contents,
            localizedFailures: localizedEnumerationFailures()
        )
    }

    public nonisolated func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options, behaviorOverride: nil, baseDepth: 0)
    }

    /// Rescans one subtree of a previous scan so its result can be spliced
    /// back into the baseline tree. `behavior` and `baseDepth` come from the
    /// original scan (root behavior and the subtree root's depth in the
    /// baseline), so depth-gated decisions — auto-summarization above all —
    /// fire exactly as they would have in a full scan.
    nonisolated func scanSubtree(
        target: ScanTarget,
        options: ScanOptions,
        behavior: ScanBehavior,
        baseDepth: Int
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options, behaviorOverride: behavior, baseDepth: baseDepth)
    }

    private nonisolated func scan(
        target: ScanTarget,
        options: ScanOptions,
        behaviorOverride: ScanBehavior?,
        baseDepth: Int
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        // Bounded, newest-wins: a stalled consumer must not queue an
        // unbounded backlog of `.partial` trees (each one a full copy of the
        // tree so far — an effective memory bomb on large scans). Progress
        // and partial events are cumulative, so dropping the oldest is safe;
        // `.finished` is always the newest event and is never dropped.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let snapshot = try await self.performScan(
                        target: target,
                        options: options,
                        behaviorOverride: behaviorOverride,
                        baseDepth: baseDepth,
                        continuation: continuation
                    )
                    continuation.yield(.finished(snapshot))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // The scan path stays `nonisolated` (no global-actor inference) so
    // overlapping scans make progress independently; see the type comment.
    private nonisolated func performScan(
        target: ScanTarget,
        options: ScanOptions,
        behaviorOverride: ScanBehavior? = nil,
        baseDepth: Int = 0,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws -> ScanSnapshot {
        let startedAt = Date()
        var metrics = ScanMetrics()
        var warnings: [ScanWarning] = []
        var emissionState = ScanEmissionState()
        let behavior = behaviorOverride ?? ScanBehavior(
            excludesStartupVolumeInternals: target.kind == .volume && target.url.path == "/"
        )
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns,
            rootPath: options.exclusionRootPath ?? target.url.path,
            includeCloudStorage: options.includeCloudStorage,
            cloudStorageRootPath: options.cloudStorageRootPath,
            iCloudDriveRootPath: options.iCloudDriveRootPath
        )

        let treeStore = try await scanDirectory(
            target: target,
            includeVolumeDetails: true,
            options: options,
            behavior: behavior,
            baseDepth: baseDepth,
            exclusionMatcher: exclusionMatcher,
            metrics: &metrics,
            warnings: &warnings,
            continuation: continuation,
            emissionState: &emissionState
        )
        metrics.completedItems = max(metrics.completedItems, metrics.discoveredItems)
        metrics.currentPath = "Summarizing results…"
        metrics.isFinalizing = true
        continuation.yield(.progress(metrics))

        let snapshot = makeSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: Date(),
            warnings: warnings,
            isComplete: true,
            scanOptions: options,
            expectedTotalBytes: exclusionMatcher.isEmpty ? metrics.estimatedTotalBytes : 0
        )

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        #if DEBUG
        if let diagnostics {
            print(diagnostics.makeReport(targetPath: target.url.path, elapsedSeconds: Date().timeIntervalSince(startedAt)))
        }
        #endif
        return snapshot
    }

    // MARK: - Iterative Directory Scanning

    /// Scans a directory iteratively (no recursion) and returns a fully
    /// assembled flat tree. The traversal's mutable state (metrics, warnings,
    /// emission throttling, work stack, assembly maps) lives in a
    /// `ScanTraversal` confined to this scan's task.
    private nonisolated func scanDirectory(
        target: ScanTarget,
        includeVolumeDetails: Bool,
        options: ScanOptions,
        behavior: ScanBehavior,
        baseDepth: Int = 0,
        exclusionMatcher: ScanExclusionMatcher,
        metrics: inout ScanMetrics,
        warnings: inout [ScanWarning],
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> FileTreeStore {
        let traversal = ScanTraversal(
            target: target,
            includeVolumeDetails: includeVolumeDetails,
            options: options,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            continuation: continuation,
            metadataLoader: metadataLoader,
            directoryContents: directoryContents,
            atomicDirectorySummarizer: atomicDirectorySummarizer,
            volumeFileSystemTypeProvider: volumeFileSystemTypeProvider,
            diagnostics: diagnostics,
            bulkEnumerationEnabled: bulkEnumerationEnabled,
            baseDepth: baseDepth,
            metrics: metrics,
            warnings: warnings,
            emissionState: emissionState
        )
        defer {
            metrics = traversal.metrics
            warnings = traversal.warnings
            emissionState = traversal.emissionState
        }
        return try await traversal.run()
    }

    // MARK: - Helpers

    /// Partial trees materialize only this many levels below the scan root;
    /// deeper content is rolled up into its depth-limit ancestor, which
    /// appears as a childless directory with correct running totals. This
    /// keeps each emission's cost proportional to the (small) top of the
    /// tree instead of everything scanned so far. `NEODISK_SCAN_PARTIAL_DEPTH`
    /// overrides it; values below 1 disable the limit.
    static let defaultPartialTreeMaxDepth = 6

    nonisolated static let partialTreeMaxDepth: Int = {
        guard let raw = ProcessInfo.processInfo.environment["NEODISK_SCAN_PARTIAL_DEPTH"],
              let value = Int(raw) else {
            return defaultPartialTreeMaxDepth
        }
        return value < 1 ? Int.max : value
    }()

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
        completedByKey: [Int: CompletedDirScan],
        childrenKeysByKey: [Int: [Int]],
        nextKey: Int,
        maxDepth: Int = partialTreeMaxDepth
    ) -> FileTreeStore? {
        guard !completedByKey.isEmpty else { return nil }

        // Children always have higher keys than their parents, so a reverse
        // pass resolves every child before its parent needs it.
        var resolvedNodeByKey: [Int: FileNodeRecord] = [:]
        var totalsByKey: [Int: PartialSubtreeTotals] = [:]
        var childrenByID: [String: [FileNodeRecord]] = [:]

        for key in (0..<nextKey).reversed() {
            guard let completed = completedByKey[key] else { continue }

            if completed.depth > maxDepth {
                // Below the emission depth: roll up numbers only.
                if completed.isTraversable {
                    var totals = PartialSubtreeTotals()
                    totals.isAccessible = completed.metadata.isReadable
                    for childKey in childrenKeysByKey[key] ?? [] {
                        if let childTotals = totalsByKey.removeValue(forKey: childKey) {
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
                    for childKey in childrenKeysByKey[key] ?? [] {
                        if let childTotals = totalsByKey.removeValue(forKey: childKey) {
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
                    var childNodes: [FileNodeRecord] = []
                    if let childKeys = childrenKeysByKey[key] {
                        childNodes.reserveCapacity(childKeys.count)
                        for childKey in childKeys {
                            if let childNode = resolvedNodeByKey.removeValue(forKey: childKey) {
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
        cancellationCheck: @escaping CancellationCheck
    ) async throws -> DirectoryContentsScanResult {
        try cancellationCheck()

        if usesBulkEnumeration {
            do {
                return try bulkDirectoryEntries(
                    of: url,
                    includeHiddenFiles: includeHiddenFiles,
                    behavior: behavior,
                    exclusionMatcher: exclusionMatcher,
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
    private nonisolated static func bulkDirectoryEntries(
        of url: URL,
        includeHiddenFiles: Bool,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck
    ) throws -> DirectoryContentsScanResult {
        #if DEBUG
        let enumerationStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let children = try BulkDirectoryReader.children(
            ofDirectory: url,
            cancellationCheck: cancellationCheck
        )

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(children.count)
        for child in children {
            if !includeHiddenFiles && child.isHidden { continue }
            guard includedChildName(child.name, under: url, behavior: behavior) else { continue }

            if let entryErrno = child.entryErrno {
                let childURL = url.appending(path: child.name)
                entries.append(DirectoryEntry(
                    url: childURL,
                    metadata: nil,
                    localizedEnumerationError: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(entryErrno),
                        userInfo: [NSURLErrorKey: childURL]
                    )
                ))
                continue
            }

            guard let metadata = child.metadata else { continue }
            let childURL = url.appending(
                path: child.name,
                directoryHint: metadata.isDirectory ? .isDirectory : .notDirectory
            )
            guard !exclusionMatcher.excludes(childURL, isDirectory: metadata.isDirectory) else { continue }
            entries.append(DirectoryEntry(url: childURL, metadata: metadata))
        }

        #if DEBUG
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: children.count,
            enumerationNanoseconds: DispatchTime.now().uptimeNanoseconds - enumerationStart,
            classificationNanoseconds: 0
        )
        #else
        return DirectoryContentsScanResult(
            entries: entries,
            enumeratedItemCount: children.count
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
                url: failure.url,
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

            let childMetadata = try? metadataLoader.metadata(
                for: childURL,
                prefetchedResourceValues: childURL.resourceValues(forKeys: resourceKeys)
            )
            guard !exclusionMatcher.excludes(
                childURL,
                isDirectory: childMetadata?.isDirectory ?? childURL.hasDirectoryPath
            ) else {
                continue
            }

            entries.append((offset + localOffset, DirectoryEntry(url: childURL, metadata: childMetadata)))
        }

        try cancellationCheck()
        return entries
    }

    private nonisolated static func shouldFilterStartupVolumeInternals(under parentURL: URL, behavior: ScanBehavior) -> Bool {
        behavior.excludesStartupVolumeInternals && ["/", "/System"].contains(parentURL.path)
    }

    nonisolated static func includedChildURL(_ childURL: URL, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        includedChildName(childURL.lastPathComponent, under: parentURL, behavior: behavior)
    }

    nonisolated static func includedChildName(_ childName: String, under parentURL: URL, behavior: ScanBehavior) -> Bool {
        let parentPath = parentURL.path

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

    private nonisolated func makeSnapshot(
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        scanOptions: ScanOptions?,
        expectedTotalBytes: Int64 = 0
    ) -> ScanSnapshot {
        let reconciledStore = reconcileVolumeRoot(treeStore, for: target, expectedTotalBytes: expectedTotalBytes)

        return ScanSnapshot(
            target: target,
            treeStore: reconciledStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: reconciledStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions
        )
    }

    private nonisolated func reconcileVolumeRoot(_ treeStore: FileTreeStore, for target: ScanTarget, expectedTotalBytes: Int64) -> FileTreeStore {
        let root = treeStore.root
        guard target.kind == .volume, expectedTotalBytes > root.allocatedSize else {
            return treeStore
        }

        let missingBytes = expectedTotalBytes - root.allocatedSize
        guard missingBytes >= 64 * 1_024 * 1_024 else {
            return treeStore
        }

        let unattributedNode = FileNodeRecord(
            id: "\(root.id)#system-unattributed",
            url: target.url,
            name: "System & Unattributed",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: missingBytes,
            logicalSize: missingBytes,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )

        let rootChildren = treeStore.children(of: root.id) + [unattributedNode]
        let sortedRootChildren = FileTreeStore.sortedChildren(rootChildren)
        let reconciledRoot = FileNodeRecord.directory(
            id: root.id,
            url: root.url,
            name: root.name,
            children: sortedRootChildren,
            lastModified: root.lastModified,
            fileIdentity: root.fileIdentity,
            linkCount: root.linkCount,
            isPackage: root.isPackage,
            isAccessible: root.isSelfAccessible,
            childrenAreSorted: true
        )

        let baseStats = treeStore.aggregateStats
        let reconciledStats = ScanAggregateStats(
            totalAllocatedSize: reconciledRoot.allocatedSize,
            totalLogicalSize: reconciledRoot.logicalSize,
            fileCount: baseStats.fileCount,
            directoryCount: baseStats.directoryCount,
            accessibleItemCount: baseStats.accessibleItemCount + 1,
            inaccessibleItemCount: baseStats.inaccessibleItemCount
        )

        return FileTreeStore(
            trustedStorage: treeStore.storage.insertingRootChild(
                unattributedNode,
                updatedRoot: reconciledRoot,
                rootChildOrder: sortedRootChildren.map(\.id)
            ),
            rootID: treeStore.rootID,
            aggregateStats: reconciledStats
        )
    }

}

extension FileManager.DirectoryEnumerator: nonisolated ScanEngine.DirectoryObjectEnumerating {}

nonisolated struct ScanEmissionState: Sendable {
    var lastProgressEmission: Date

    nonisolated init(
        lastProgressEmission: Date = .distantPast
    ) {
        self.lastProgressEmission = lastProgressEmission
    }
}
