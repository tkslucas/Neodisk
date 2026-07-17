//
//  ScanIncrementalModels.swift
//  Neodisk
//
//  Shared value types for incremental FSEvents rescans: the persisted
//  journal checkpoint, filesystem-independent change events, and the
//  planner's verdict. The FSEvents C API never leaks past the Darwin
//  history provider — everything here is plain Swift so the planner and
//  scan service stay unit-testable without a real filesystem.
//

import Foundation

/// A point in a volume's FSEvents journal, captured at scan start and
/// persisted with the snapshot. A later rescan replays the journaled events
/// after `eventID` to learn which directories changed; everything about the
/// replay is a hint — re-enumeration of the named directories is the only
/// source of truth, and any doubt about the checkpoint's validity falls back
/// to a full scan.
public struct FSEventsCheckpoint: Hashable, Codable, Sendable {
    /// `FSEventsCopyUUIDForDevice` of the volume backing the scan target,
    /// lowercased. The journal gets a fresh UUID whenever fseventsd discards
    /// or rebuilds it, so a mismatch means every stored event ID is
    /// meaningless.
    public let volumeUUID: String
    /// The most recent journal event ID at capture time (device-relative
    /// stream semantics — IDs are only comparable on the same device).
    public let eventID: UInt64
    /// Wall-clock capture time. The journal is a rolling, size-bounded
    /// record with no API signal for "your checkpoint aged out", so
    /// checkpoints older than `FSEventsCheckpoint.maxTrustedAge` are
    /// refused outright.
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

    /// How long a persisted checkpoint stays trusted. The fseventsd journal
    /// realistically retains days-to-weeks of history on an active system
    /// and silently replays an incomplete window once it has rotated past a
    /// stored ID — age is the only guard against that gap.
    public static let maxTrustedAge: TimeInterval = 14 * 24 * 60 * 60
}

/// Filesystem-independent projection of the FSEvents per-event flags the
/// incremental pipeline cares about. The Darwin provider translates
/// `kFSEventStreamEventFlag*` bits into these; nothing downstream imports
/// CoreServices.
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

    /// Flags that individually invalidate the whole replay.
    var demandsFullScan: Bool {
        !isDisjoint(with: [.userDropped, .kernelDropped, .eventIDsWrapped, .rootChanged, .volumeMounted, .volumeUnmounted])
    }

    /// Whether the event names an item whose parent directory's membership
    /// may have changed (create/remove/rename) — those must re-enumerate the
    /// parent, not just the named path.
    var indicatesMembershipChange: Bool {
        !isDisjoint(with: [.itemCreated, .itemRemoved, .itemRenamed])
    }
}

/// One journaled change, with `path` already absolute and firmlink-normalized
/// into the same namespace the scan tree uses (`/System/Volumes/Data/...`
/// forms are translated back to their firmlinked `/...` equivalents).
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

/// Reads the FSEvents journal for incremental rescans. One transient stream
/// per `history` call, drained to the HistoryDone sentinel and torn down —
/// never a persistent watcher.
protocol FileSystemEventHistoryProviding: Sendable {
    /// The journal position for the volume containing `target`, captured
    /// before a scan starts so the next rescan replays everything that
    /// changed during and after this scan.
    func currentCheckpoint(for target: ScanTarget) throws -> FSEventsCheckpoint

    /// Replays journaled events in `(since.eventID, through.eventID]` for
    /// paths under `target`. Validates the checkpoint pair (UUID match, no
    /// rollback, age, OS build) and throws `FileSystemEventHistoryError` on
    /// any doubt.
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
    case cloudTarget
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
    case changedScanRoot
    case eventOutsideTarget
    case noMaterializedAncestor
    case tooManyChangedSubtrees
    case subtreeVanished
    case subtreeScanFailed
    case spliceFailed
    case rootRelistEnumerationFailed
    case rootRelistFailed
}

/// The planner's verdict for one replayed history.
enum IncrementalRescanPlan: Sendable, Equatable {
    case noChanges
    /// Minimal set of existing, disjoint subtree roots (node IDs in the
    /// baseline tree) to re-enumerate and splice.
    case rescanSubtrees([String])
    /// The scan root's own membership changed (a child appeared/vanished, a
    /// direct-child file changed, or the root's own record moved). The service
    /// shallow-relists the root directory — one readdir, diff its direct
    /// children against the baseline — instead of discarding the whole tree.
    /// The associated IDs are the other mapped subtree roots from the same
    /// event window (deep changes), spliced together with the membership edits
    /// in one pass. An empty array means "only the root's membership/record
    /// moved". This replaces the old `.fullScan(.changedScanRoot)` bail that
    /// fired on near-every real refresh from ambient churn in the root.
    case relistRoot(subtreeRootIDs: [String])
    case fullScan(IncrementalFullScanReason)
}

extension ScanOptions {
    /// The projection of the options that changes what a scan's tree looks
    /// like. Two scans whose signatures differ cannot be spliced into each
    /// other; worker-limit tuning deliberately excluded (parallelism never
    /// changes shape).
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
