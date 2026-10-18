#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Not an actor: every stored property is `let`, and actor serialization once let a cancelling scan
/// block a new one (testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling).
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
        /// Never given scan keys: batching them here keeps millions of leaves out of the coordinator's
        /// dictionaries.
        let directLeafNodes: [FileNodeRecord]
        /// Sorted by the directory workers, so assembly only places the subfolders among them.
        let directLeafNodesAreSorted: Bool
        /// The sum of `directLeafNodes` when the worker already took it.
        let directLeafTotals: PartialSubtreeTotals?
        let metadata: NodeMetadata
        let url: URL
        /// Derived once on the directory task since assembly and every partial read them. Always the URL's own
        /// (decomposed) spelling, never the path string's, so node ids keep their bytes.
        let path: String
        let name: String
        let isTraversable: Bool     // True if this was a directory we intended to traverse.
        let depth: Int              // Levels below the scan root (root is 0).

        init(
            node: FileNodeRecord?,
            directLeafNodes: [FileNodeRecord] = [],
            directLeafNodesAreSorted: Bool = false,
            directLeafTotals: PartialSubtreeTotals? = nil,
            metadata: NodeMetadata,
            url: URL,
            pathAndName: (path: String, name: String)? = nil,
            isTraversable: Bool,
            depth: Int
        ) {
            self.path = pathAndName?.path ?? url.path
            self.name = pathAndName?.name ?? ScanTarget.displayName(for: url)
            self.node = node
            self.directLeafNodes = directLeafNodes
            self.directLeafNodesAreSorted = directLeafNodesAreSorted || directLeafNodes.count < 2
            self.directLeafTotals = directLeafTotals
            self.metadata = metadata
            self.url = url
            self.isTraversable = isTraversable
            self.depth = depth
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
    /// Only the real filesystem engine enables this: injected test providers must stay authoritative.
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
        #if os(Linux)
        return LinuxMountTable.fileSystemType(forPath: url.path)
        #else
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
        #endif
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

    /// `behavior` and `baseDepth` come from the original scan so depth-gated decisions (auto-summarization)
    /// fire exactly as in a full scan.
    nonisolated func scanSubtree(
        target: ScanTarget,
        options: ScanOptions,
        behavior: ScanBehavior,
        baseDepth: Int
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        scan(target: target, options: options, behaviorOverride: behavior, baseDepth: baseDepth)
    }

    /// Enough to diff membership against the baseline without rescanning a subtree; only leaves are
    /// materialized.
    struct ShallowChild: Sendable {
        let url: URL
        /// An unreadable child is a leaf: a childless inaccessible node, as a full scan collapses it.
        let isDirectoryLike: Bool
        /// Nil only for a directory-like child, which is left to its own relist.
        let leafRecord: FileNodeRecord?
        /// Still carries an inaccessible `leafRecord` and `warning`, so the relist matches a full scan inline.
        let isUnavailable: Bool
        /// The warning a full scan emits for an unreadable child, else nil.
        let warning: ScanWarning?
    }

    /// Same inclusion gates as a full scan's enumeration, so a relist diffed against it can't drift
    /// from a fresh scan's membership. One readdir, no recursion.
    nonisolated func directChildren(
        of url: URL,
        options: ScanOptions,
        behavior: ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher
    ) async throws -> [ShallowChild] {
        let contents = try await ScanEngine.directoryEntries(
            of: url,
            includeHiddenFiles: options.includeHiddenFiles,
            behavior: behavior,
            exclusionMatcher: exclusionMatcher,
            resourceKeys: ScanMetadataLoader.scanResourceKeys,
            metadataLoader: metadataLoader,
            directoryContents: directoryContents,
            classificationWorkerLimit: 1,
            usesBulkEnumeration: bulkEnumerationEnabled,
            cancellationCheck: { try Task.checkCancellation() }
        )
        return contents.entries.map { entry in
            guard entry.localizedEnumerationError == nil, let metadata = entry.metadata else {
                if let enumError = entry.localizedEnumerationError {
                    return unavailableChild(entry: entry, error: enumError)
                }
                // Missing metadata with no error: retry once like the traversal, since it may be a transient
                // bulk gap.
                do {
                    return availableChild(entry: entry, metadata: try metadataLoader.metadata(for: entry.url))
                } catch {
                    return unavailableChild(entry: entry, error: error)
                }
            }
            return availableChild(entry: entry, metadata: metadata)
        }
    }

    private nonisolated func availableChild(
        entry: DirectoryEntry, metadata: NodeMetadata
    ) -> ShallowChild {
        let isDirectoryLike = metadata.isDirectory && !metadata.isSymbolicLink
        return ShallowChild(
            url: entry.url,
            isDirectoryLike: isDirectoryLike,
            leafRecord: isDirectoryLike
                ? nil
                : atomicDirectorySummarizer.makeFileNode(path: entry.path, name: entry.name, metadata: metadata),
            isUnavailable: false,
            warning: nil
        )
    }

    /// Childless and inaccessible, so a relist splices it inline and matches a fresh scan.
    private nonisolated func unavailableChild(
        entry: DirectoryEntry, error: Error
    ) -> ShallowChild {
        let isDirectory: Bool
        if let metadata = entry.metadata {
            isDirectory = metadata.isDirectory && !metadata.isSymbolicLink
        } else {
            isDirectory = entry.isDirectoryHint ?? entry.url.hasDirectoryPath
        }
        return ShallowChild(
            url: entry.url,
            isDirectoryLike: false,
            leafRecord: FileNodeRecord.inaccessible(path: entry.path, isDirectory: isDirectory),
            isUnavailable: true,
            warning: ScanWarningFactory.makeWarning(for: entry.url, error: error)
        )
    }

    /// The root directory's own refreshed record (mtime etc.) for a relist,
    /// or nil when the load fails. Reads only the root itself.
    nonisolated func rootDirectoryMetadata(of url: URL) -> NodeMetadata? {
        try? metadataLoader.metadata(for: url, captureDirectoryIdentity: true)
    }

    /// The traversal's exact summary gate. A relist re-walks a directory that trips it so the outcome matches
    /// a full scan, instead of splicing children into a directory the traversal would have collapsed.
    nonisolated func isRelistSummaryCandidate(
        directoryURL: URL,
        depth: Int,
        directChildCount: Int,
        hasDirectoryChild: Bool,
        options: ScanOptions
    ) -> Bool {
        guard options.autoSummarizeDirectories else { return false }
        let minDepth = options.tuning.autoSummarizeMinDepthForSummarization
            ?? ScanTraversal.AtomicDirectoryThresholds.minDepthForSummarization
        let minFileCount = options.tuning.autoSummarizeMinFileCount
            ?? ScanTraversal.AtomicDirectoryThresholds.minFileCount
        let isNodeDependencyLayout = AtomicDirectorySummarizer.isNodeDependencyLayoutDirectory(at: directoryURL)
        let isKnownGeneratedDirectory = AtomicDirectorySummarizer.isKnownGeneratedDirectory(at: directoryURL)
        let canProbe = depth >= minDepth
            || (depth >= 1 && isNodeDependencyLayout)
            || isKnownGeneratedDirectory
        guard canProbe else { return false }
        return atomicDirectorySummarizer.isSummaryProbeWorthwhile(
            directChildCount: directChildCount,
            hasDirectoryChild: hasDirectoryChild,
            minFileCount: minFileCount,
            isKnownGeneratedDirectory: isKnownGeneratedDirectory,
            isNodeDependencyLayout: isNodeDependencyLayout
        )
    }

    private nonisolated func scan(
        target: ScanTarget,
        options: ScanOptions,
        behaviorOverride: ScanBehavior?,
        baseDepth: Int
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        // Bounded, newest-wins: each `.partial` is a full tree copy, so a stalled consumer would blow up
        // memory. Events are cumulative so dropping the oldest is safe; `.finished` is always newest.
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
            scanOptions: options
        )

        metrics.isFinalizing = false
        metrics.currentPath = target.url.path
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        ScanTiming.record(
            "scan.total",
            .seconds(Date().timeIntervalSince(startedAt)),
            detail: "files=\(snapshot.aggregateStats.fileCount) dirs=\(snapshot.aggregateStats.directoryCount) "
                + "nodes=\(treeStore.nodeCount) warnings=\(warnings.count) target=\(target.url.path)"
        )
        #if DEBUG
        if let diagnostics {
            print(diagnostics.makeReport(targetPath: target.url.path, elapsedSeconds: Date().timeIntervalSince(startedAt)))
        }
        #endif
        return snapshot
    }

    // MARK: - Iterative Directory Scanning

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

    /// Deeper content rolls up into its depth-limit ancestor, keeping each emission's cost small.
    /// `NEODISK_SCAN_PARTIAL_DEPTH` overrides it; below 1 disables the limit.
    static let defaultPartialTreeMaxDepth = 6

    nonisolated static let partialTreeMaxDepth: Int = {
        guard let raw = ProcessInfo.processInfo.environment["NEODISK_SCAN_PARTIAL_DEPTH"],
              let value = Int(raw) else {
            return defaultPartialTreeMaxDepth
        }
        return value < 1 ? Int.max : value
    }()

    /// The gap up to used capacity is shown by the UI as hidden space, never as a synthetic node.
    private nonisolated func makeSnapshot(
        target: ScanTarget,
        treeStore: FileTreeStore,
        startedAt: Date,
        finishedAt: Date?,
        warnings: [ScanWarning],
        isComplete: Bool,
        scanOptions: ScanOptions?
    ) -> ScanSnapshot {
        ScanSnapshot(
            target: target,
            treeStore: treeStore,
            startedAt: startedAt,
            finishedAt: finishedAt,
            scanWarnings: warnings,
            aggregateStats: treeStore.aggregateStats,
            isComplete: isComplete,
            scanOptions: scanOptions
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
