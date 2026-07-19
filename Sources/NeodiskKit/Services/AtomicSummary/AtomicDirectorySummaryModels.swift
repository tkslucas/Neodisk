//
//  AtomicDirectorySummaryModels.swift
//  Neodisk
//

import Foundation

typealias CancellationCheck = @Sendable () throws -> Void

/// A child discovered during directory enumeration.
/// Directory enumeration prefetches resource values, so carrying decoded metadata forward
/// avoids asking each URL for the same values again when the child is scanned.
nonisolated struct DirectoryEntry: Sendable {
    /// The child's absolute path (its node id) and display name, materialized
    /// once at enumeration and reused everywhere so nothing re-derives them
    /// from a `URL`. `name` is the last path component.
    let path: String
    let name: String
    let metadata: NodeMetadata?
    let localizedEnumerationError: Error?
    let isDirectoryHint: Bool?
    /// Device identity used only for traversal boundary decisions. This is
    /// populated directly by getattrlistbulk and derived from a directory's
    /// FileIdentity on the compatibility path.
    let deviceID: UInt64?
    /// ATTR_DIR_MOUNTSTATUS when bulk enumeration supplied it.
    let directoryMountStatus: UInt32

    /// Rebuilt on demand from `path`: only directories, packages, and
    /// unavailable entries ever need a `URL`; plain files go straight from
    /// `path`/`name` to a `FileNodeRecord`, so building it eagerly per entry
    /// was wasted `URL.appending`. `URL(filePath:)` is byte-equivalent to the
    /// `parent.appending(path:)` it replaces for every property the scan reads.
    var url: URL {
        let isDirectory = metadata?.isDirectory ?? isDirectoryHint ?? false
        return URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    init(
        path: String,
        name: String,
        metadata: NodeMetadata?,
        localizedEnumerationError: Error? = nil,
        isDirectoryHint: Bool? = nil,
        deviceID: UInt64? = nil,
        directoryMountStatus: UInt32 = 0
    ) {
        self.path = path
        self.name = name
        self.metadata = metadata
        self.localizedEnumerationError = localizedEnumerationError
        self.isDirectoryHint = isDirectoryHint
        self.deviceID = deviceID
        self.directoryMountStatus = directoryMountStatus
    }
}

nonisolated struct AtomicDirectorySummary: Sendable {
    let allocatedSize: Int64
    let logicalSize: Int64
    let cloudOnlyLogicalSize: Int64
    let descendantFileCount: Int
    let isAccessible: Bool
    let warnings: [ScanWarning]
    let hardLinkClaims: [HardLinkClaim]
    /// Pool jobs whose live progress contribution is still displayed. The
    /// traversal acknowledges these IDs when it folds this summary into its
    /// authoritative metrics base.
    let progressJobIDs: [Int]
}

/// One directory level to summarize. Files at this level fold into the job's
/// partial; each subdirectory becomes a new work item for the same job.
nonisolated struct AtomicSummaryWorkItem: Sendable {
    let url: URL
    let treatPackagesAsDirectories: Bool
    let ownerNodeID: String
}

/// The result of processing one directory level: the files folded into a
/// partial, plus the subdirectories discovered for further processing.
nonisolated struct AtomicSummaryWorkResult: Sendable {
    var partial: AtomicDirectorySummaryPartial
    var pendingItems: [AtomicSummaryWorkItem]
}

/// A running partial summary. `AtomicDirectorySummaryPool` keeps one per job and
/// merges each processed directory level into it under its lock.
nonisolated struct AtomicDirectorySummaryPartial: Sendable {
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var cloudOnlyLogicalSize: Int64 = 0
    var descendantFileCount = 0
    var isAccessible = true
    var warnings: [ScanWarning] = []
    var hardLinkClaims: [HardLinkClaim] = []
    var progressJobIDs: [Int] = []

    mutating func updateAccessibility(_ readable: Bool) {
        isAccessible = isAccessible && readable
    }

    mutating func recordWarning(for url: URL, error: Error) {
        isAccessible = false
        warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    mutating func accumulateFile(_ metadata: NodeMetadata, path: String, ownerNodeID: String) {
        allocatedSize = allocatedSize.addingClamped(metadata.allocatedSize)
        logicalSize = logicalSize.addingClamped(metadata.logicalSize)
        if metadata.isDataless {
            cloudOnlyLogicalSize = cloudOnlyLogicalSize.addingClamped(metadata.logicalSize)
        }
        if !metadata.isSymbolicLink {
            descendantFileCount += 1
        }
        if let claim = HardLinkDeduplicator.claim(for: metadata, ownerNodeID: ownerNodeID, path: path) {
            hardLinkClaims.append(claim)
        }
    }

    mutating func merge(_ other: AtomicDirectorySummaryPartial) {
        allocatedSize = allocatedSize.addingClamped(other.allocatedSize)
        logicalSize = logicalSize.addingClamped(other.logicalSize)
        cloudOnlyLogicalSize = cloudOnlyLogicalSize.addingClamped(other.cloudOnlyLogicalSize)
        descendantFileCount += other.descendantFileCount
        isAccessible = isAccessible && other.isAccessible
        warnings.append(contentsOf: other.warnings)
        hardLinkClaims.append(contentsOf: other.hardLinkClaims)
        progressJobIDs.append(contentsOf: other.progressJobIDs)
    }

    mutating func merge(_ summary: AtomicDirectorySummary) {
        allocatedSize = allocatedSize.addingClamped(summary.allocatedSize)
        logicalSize = logicalSize.addingClamped(summary.logicalSize)
        cloudOnlyLogicalSize = cloudOnlyLogicalSize.addingClamped(summary.cloudOnlyLogicalSize)
        descendantFileCount += summary.descendantFileCount
        isAccessible = isAccessible && summary.isAccessible
        warnings.append(contentsOf: summary.warnings)
        hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
        progressJobIDs.append(contentsOf: summary.progressJobIDs)
    }

    func makeSummary(additionalProgressJobIDs: [Int] = []) -> AtomicDirectorySummary {
        AtomicDirectorySummary(
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            cloudOnlyLogicalSize: cloudOnlyLogicalSize,
            descendantFileCount: descendantFileCount,
            isAccessible: isAccessible,
            warnings: warnings,
            hardLinkClaims: hardLinkClaims,
            progressJobIDs: progressJobIDs + additionalProgressJobIDs
        )
    }
}

/// Callbacks a directory-level walk drives so `processDirectoryLevel`'s
/// per-child classification can fold into the shared pool's per-job partial.
nonisolated struct AtomicSummaryLevelSink {
    /// `onVisit`/`onFile` take the child's path string (progress, hard-link
    /// claim key) so the bulk walker builds no per-child `URL`; `onWarning`/
    /// `onSubdirectory` keep `URL`s, built only for rare errors and recursion.
    let onVisit: (String) -> Void
    let onAccessibility: (Bool) -> Void
    let onWarning: (URL, Error) -> Void
    let onFile: (NodeMetadata, String) -> Void
    let onSubdirectory: (AtomicSummaryWorkItem) -> Void
}

/// A completed leaf (file, symlink, or summarized package) awaiting insertion
/// into the tree. `Sendable` so it can be returned from a scan task-group child.
nonisolated struct LeafNodeResult: Sendable {
    let node: FileNodeRecord
    let warnings: [ScanWarning]
    let hardLinkClaims: [HardLinkClaim]
    let minimumAllocatedSize: Int64?
    let progressJobIDs: [Int]
}

/// Reference-typed holder for the immediate-children reuse path, which mutates
/// one running partial as it folds each child. Accumulation semantics live
/// entirely in `AtomicDirectorySummaryPartial`.
nonisolated final class AtomicDirectorySummaryState {
    var partial = AtomicDirectorySummaryPartial()
    let ownerNodeID: String

    init(ownerNodeID: String) {
        self.ownerNodeID = ownerNodeID
    }
}

nonisolated struct AtomicDirectoryProbeProfile: Sendable {
    var observedFileCount = 0
    var observedDirectoryCount = 0
    var totalSampledLogicalSize: Int64 = 0
    var observedNodeDependencyLayout = false

    func suggestsAtomicDirectory(minFileCount: Int, maxAverageFileSize: Int64) -> Bool {
        guard observedFileCount > 0, observedFileCount >= minFileCount else { return false }
        return (totalSampledLogicalSize / Int64(observedFileCount)) <= maxAverageFileSize
    }
}
