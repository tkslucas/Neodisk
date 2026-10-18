// Plain Swift types for incremental FSEvents rescans; the C API never leaks past the Darwin provider,
// so the planner and scan service stay unit-testable.

import Foundation

/// The replayed events are only a hint: re-enumeration is the source of truth, and any doubt about the
/// checkpoint falls back to a full scan.
public struct FSEventsCheckpoint: Hashable, Codable, Sendable {
    /// Lowercased. The journal gets a fresh UUID whenever fseventsd rebuilds it, so a mismatch voids every
    /// event ID.
    public let volumeUUID: String
    /// The most recent journal event ID at capture time (device-relative
    /// stream semantics — IDs are only comparable on the same device).
    public let eventID: UInt64
    /// The journal is rolling with no "aged out" signal, so checkpoints older than `maxTrustedAge` are refused.
    public let capturedAt: Date
    /// `kern.osversion` at capture. Major macOS updates flush the journal
    /// without changing its UUID; a build change invalidates the checkpoint.
    public let osBuild: String

    public init(volumeUUID: String, eventID: UInt64, capturedAt: Date, osBuild: String) {
        self.volumeUUID = volumeUUID.lowercased()
        self.eventID = eventID
        self.capturedAt = capturedAt
        self.osBuild = osBuild
    }

    /// The journal silently replays an incomplete window once it rotates past a stored ID; age is the only
    /// guard.
    public static let maxTrustedAge: TimeInterval = 14 * 24 * 60 * 60
}

/// Translated from `kFSEventStreamEventFlag*` bits so nothing downstream imports CoreServices.
struct FileSystemEventFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt32

    /// Events were coalesced hierarchically: the path and everything below
    /// it must be re-enumerated.
    static let mustScanSubdirectories = FileSystemEventFlags(rawValue: 1 << 0)
    static let userDropped = FileSystemEventFlags(rawValue: 1 << 1)
    static let kernelDropped = FileSystemEventFlags(rawValue: 1 << 2)
    static let eventIDsWrapped = FileSystemEventFlags(rawValue: 1 << 3)
    /// The watched root itself moved or was renamed (event ID 0).
    static let rootChanged = FileSystemEventFlags(rawValue: 1 << 4)
    static let volumeMounted = FileSystemEventFlags(rawValue: 1 << 5)
    static let volumeUnmounted = FileSystemEventFlags(rawValue: 1 << 6)
    /// End-of-replay sentinel; never surfaced in a history's events.
    static let historyDone = FileSystemEventFlags(rawValue: 1 << 7)
    static let itemIsDirectory = FileSystemEventFlags(rawValue: 1 << 8)
    static let itemCreated = FileSystemEventFlags(rawValue: 1 << 9)
    static let itemRemoved = FileSystemEventFlags(rawValue: 1 << 10)
    static let itemRenamed = FileSystemEventFlags(rawValue: 1 << 11)
    /// The named item is a hard link (link count > 1) — set on the event
    /// that created the link and on later events for any of its links.
    static let itemIsHardLink = FileSystemEventFlags(rawValue: 1 << 12)
    /// The named item was the last remaining hard link to its file.
    static let itemIsLastHardLink = FileSystemEventFlags(rawValue: 1 << 13)

    /// Flags that individually invalidate the whole replay.
    var demandsFullScan: Bool {
        !isDisjoint(with: [.userDropped, .kernelDropped, .eventIDsWrapped, .rootChanged, .volumeMounted, .volumeUnmounted])
    }

    /// Create/remove/rename must re-enumerate the parent, not just the named path.
    var indicatesMembershipChange: Bool {
        !isDisjoint(with: [.itemCreated, .itemRemoved, .itemRenamed])
    }

    /// Dedup charges a shared file to one link tree-wide, and the journal names only the link that changed,
    /// so a shallow relist of that directory can't reproduce a full scan's ownership.
    var touchesHardLink: Bool {
        !isDisjoint(with: [.itemIsHardLink, .itemIsLastHardLink])
    }
}

/// `/System/Volumes/Data/...` paths are translated back to their firmlinked `/...` forms.
struct FileSystemChangeEvent: Sendable, Hashable {
    let path: String
    let eventID: UInt64
    let flags: FileSystemEventFlags
}

/// The replayed journal window `(since, through]` for one target.
struct FileSystemEventHistory: Sendable {
    let events: [FileSystemChangeEvent]

    init(events: [FileSystemChangeEvent]) {
        self.events = events
    }
}

/// Why the incremental path refused a checkpoint or replay. Every case is a
/// silent fall-back-to-full-scan, never a user-facing error.
enum FileSystemEventHistoryError: Error, Equatable {
    /// The platform keeps no persistent change journal to replay (Linux:
    /// inotify/fanotify only see changes while a watcher runs).
    case unsupportedPlatform
    /// The target's volume is not MNT_LOCAL (network mounts have no
    /// trustworthy journal).
    case nonLocalVolume
    case eventIDUnavailable
    case volumeUUIDUnavailable
    case targetUnavailable
    case targetIsNotDirectory
    /// Live volume UUID differs from the checkpoint's.
    case volumeChanged
    /// Current journal position is behind the checkpoint (restore from
    /// backup, purge, or wrap).
    case eventIDRolledBack
    case invalidCheckpointRange
    /// The checkpoint predates `FSEventsCheckpoint.maxTrustedAge` — the
    /// journal may have rotated past it with no way to detect the gap.
    case checkpointExpired
    /// The OS build changed since capture; major updates flush the journal.
    case osBuildChanged
    case streamCreationFailed
    case streamStartFailed
    /// HistoryDone never arrived within the replay deadline.
    case historyReplayTimedOut
    /// More distinct in-window changed paths than the replay budget retains;
    /// a full scan is cheaper than planning over them.
    case eventBudgetExceeded
}

/// One transient stream per `history` call, drained to HistoryDone and torn down; never a persistent watcher.
protocol FileSystemEventHistoryProviding: Sendable {
    /// Captured before a scan starts so the next rescan also replays changes made during this scan.
    func currentCheckpoint(for target: ScanTarget) throws -> FSEventsCheckpoint

    /// Replays `(since.eventID, through.eventID]` under `target`; throws `FileSystemEventHistoryError` on any
    /// doubt about the checkpoint pair (UUID, rollback, age, OS build).
    func history(
        since: FSEventsCheckpoint,
        through: FSEventsCheckpoint,
        target: ScanTarget
    ) async throws -> FileSystemEventHistory
}

/// Why an incremental rescan degraded to a full scan.
enum IncrementalFullScanReason: String, Sendable, Equatable {
    case incrementalDisabled
    case noBaseline
    case baselineIncomplete
    case baselineNotPersistable
    case targetMismatch
    case scanOptionsChanged
    case missingCheckpoint
    case unattributedVolumeNode
    case checkpointInvalid
    case historyUnavailable
    case historyBudgetExceeded
    case historyReplayTimedOut
    case userDroppedEvents
    case kernelDroppedEvents
    case eventIDsWrapped
    case watchedRootChanged
    case nestedVolumeChanged
    /// A hard link was created, removed, or written through; scan-wide
    /// shared-size ownership can't be rebuilt from a partial relist.
    case hardLinkTopologyChanged
    case changedScanRoot
    case eventOutsideTarget
    case noMaterializedAncestor
    case tooManyChangedSubtrees
    case subtreeVanished
    case subtreeScanFailed
    case spliceFailed
    case rootRelistEnumerationFailed
}

/// The planner's verdict for one replayed history.
enum IncrementalRescanPlan: Sendable, Equatable {
    case noChanges
    /// `dirIDs` are shallow-relisted, one readdir each. `deepRescanRootIDs` need a full re-walk:
    /// MustScanSubDirs coalesces, and summarized dirs whose interior the baseline never had.
    case relistDirectories(dirIDs: [String], deepRescanRootIDs: [String])
    case fullScan(IncrementalFullScanReason)
}

extension ScanOptions {
    /// Signatures that differ can't be spliced; worker limits are excluded since parallelism never changes
    /// shape.
    struct ShapeSignature: Hashable, Sendable {
        let includeHiddenFiles: Bool
        let treatPackagesAsDirectories: Bool
        let treatRootPackageAsDirectory: Bool
        let autoSummarizeDirectories: Bool
        let includeCloudStorage: Bool
        let cloudStorageRootPath: String
        let iCloudDriveRootPath: String
        let exclusionPatterns: [String]
        let exclusionRootPath: String?
        let autoSummarizeMinFileCount: Int?
        let autoSummarizeMaxAverageFileSize: Int64?
        let autoSummarizeMinDepthForSummarization: Int?
    }

    var shapeSignature: ShapeSignature {
        ShapeSignature(
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            treatRootPackageAsDirectory: treatRootPackageAsDirectory,
            autoSummarizeDirectories: autoSummarizeDirectories,
            includeCloudStorage: includeCloudStorage,
            cloudStorageRootPath: cloudStorageRootPath,
            iCloudDriveRootPath: iCloudDriveRootPath,
            exclusionPatterns: exclusionPatterns,
            exclusionRootPath: exclusionRootPath,
            autoSummarizeMinFileCount: tuning.autoSummarizeMinFileCount,
            autoSummarizeMaxAverageFileSize: tuning.autoSummarizeMaxAverageFileSize,
            autoSummarizeMinDepthForSummarization: tuning.autoSummarizeMinDepthForSummarization
        )
    }
}
