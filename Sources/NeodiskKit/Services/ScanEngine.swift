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
            scanOptions: options
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

    /// Volume snapshots carry only what the scan itself accounted for; the
    /// gap up to the volume's used capacity is presented uniformly by the
    /// UI as hidden space (VolumeSpaceInfo), never as a synthetic node.
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
