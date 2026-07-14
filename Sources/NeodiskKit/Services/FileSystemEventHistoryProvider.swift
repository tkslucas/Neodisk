//
//  FileSystemEventHistoryProvider.swift
//  Neodisk
//
//  Darwin implementation of `FileSystemEventHistoryProviding`. It reads the
//  fseventsd journal for incremental rescans through a single transient
//  device-relative stream per `history` call — never a persistent watcher.
//  The FSEvents C API (CoreServices) is confined to this file; everything it
//  produces is translated into the plain Swift `FileSystemChangeEvent` before
//  leaving, so the planner and scan service stay CoreServices-free.
//

import CoreServices
import Darwin
import Dispatch
import Foundation

struct DarwinFileSystemEventHistoryProvider: FileSystemEventHistoryProviding {
    private let latency: CFTimeInterval
    /// How long the replay may run before we give up and force a full scan.
    /// The journal is finite, so HistoryDone normally arrives quickly; this
    /// only fires when fseventsd stalls or the stream is torn down without a
    /// terminating event (the latent hang Radix's collector could suffer).
    private let replayTimeout: DispatchTimeInterval
    /// Cap on raw events replayed before bailing to a full scan; planning over
    /// more than this is more expensive than re-enumerating.
    private let eventBudget: Int
    private let firmlinkTranslator: FirmlinkPathTranslator

    init(
        latency: CFTimeInterval = 0.05,
        replayTimeout: DispatchTimeInterval = .seconds(15),
        eventBudget: Int = 250_000,
        firmlinkTranslator: FirmlinkPathTranslator = .system
    ) {
        self.latency = max(latency, 0)
        self.replayTimeout = replayTimeout
        self.eventBudget = eventBudget
        self.firmlinkTranslator = firmlinkTranslator
    }

    func currentCheckpoint(for target: ScanTarget) throws -> FSEventsCheckpoint {
        let volume = try volumeContext(for: target)
        // Event IDs come from one host-global counter that device-relative
        // streams share, so the global current ID is a valid — and, unlike
        // `FSEventsGetLastEventIdForDeviceBeforeTime`, a FRESH — journal
        // position: the before-time lookup only consults flushed journal
        // records and lags live events by minutes, which made a rescan's
        // `(since, through]` window silently exclude everything recent.
        let eventID = FSEventsGetCurrentEventId()
        guard eventID > 0 else {
            throw FileSystemEventHistoryError.eventIDUnavailable
        }
        return FSEventsCheckpoint(
            volumeUUID: volume.uuid,
            eventID: eventID,
            capturedAt: Date(),
            osBuild: Self.currentOSBuild()
        )
    }

    func history(
        since: FSEventsCheckpoint,
        through: FSEventsCheckpoint,
        target: ScanTarget
    ) async throws -> FileSystemEventHistory {
        try Task.checkCancellation()

        let volume = try volumeContext(for: target)
        guard since.volumeUUID.caseInsensitiveCompare(volume.uuid) == .orderedSame,
              through.volumeUUID.caseInsensitiveCompare(volume.uuid) == .orderedSame else {
            throw FileSystemEventHistoryError.volumeChanged
        }
        guard through.eventID >= since.eventID else {
            throw FileSystemEventHistoryError.eventIDRolledBack
        }
        guard since.eventID > 0 else {
            throw FileSystemEventHistoryError.invalidCheckpointRange
        }
        guard Date().timeIntervalSince(since.capturedAt) <= FSEventsCheckpoint.maxTrustedAge else {
            throw FileSystemEventHistoryError.checkpointExpired
        }
        guard since.osBuild == Self.currentOSBuild() else {
            throw FileSystemEventHistoryError.osBuildChanged
        }
        // An unchanged window needs no journal replay.
        guard through.eventID > since.eventID else {
            return FileSystemEventHistory(events: [])
        }

        let collector = FSEventHistoryCollector(
            since: since,
            through: through,
            mountPoint: volume.mountPoint,
            firmlinkTranslator: firmlinkTranslator,
            eventBudget: eventBudget
        )
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [volume.relativeTargetPath] as CFArray
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagFullHistory
        )
        guard let stream = FSEventStreamCreateRelativeToDevice(
            nil,
            neodiskFSEventHistoryCallback,
            &context,
            volume.deviceID,
            paths,
            since.eventID,
            latency,
            createFlags
        ) else {
            throw FileSystemEventHistoryError.streamCreationFailed
        }

        let queue = DispatchQueue(label: "tech.pointset.neodisk.fsevents.history")
        let lifetime = FSEventStreamLifetime(stream: stream)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            lifetime.stop()
            throw FileSystemEventHistoryError.streamStartFailed
        }

        // Safety net: resume the continuation even if HistoryDone never
        // arrives (a stalled fseventsd, or the stream being invalidated
        // externally). Idempotent with the HistoryDone/cancel/budget paths.
        let timeout = DispatchWorkItem { collector.timeOut() }
        queue.asyncAfter(deadline: .now() + replayTimeout, execute: timeout)

        return try await withTaskCancellationHandler {
            defer {
                timeout.cancel()
                lifetime.stop()
            }
            return try await collector.value()
        } onCancel: {
            // `timeout` is torn down by the `defer` once `value()` unblocks; a
            // late fire is a no-op since `finish` is idempotent.
            collector.cancel()
            lifetime.stop()
        }
    }

    private struct VolumeContext {
        let deviceID: dev_t
        let uuid: String
        /// The device/volume mount point events are reported relative to. For
        /// a `/` target this is the Data volume mount, not `/`, because the
        /// root namespace's `st_dev` is the Data device.
        let mountPoint: String
        let relativeTargetPath: String
    }

    private func volumeContext(for target: ScanTarget) throws -> VolumeContext {
        let targetURL = target.url.standardizedFileURL

        var targetStat = stat()
        let statResult = targetURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &targetStat)
        }
        guard statResult == 0 else {
            throw FileSystemEventHistoryError.targetUnavailable
        }
        guard targetStat.st_mode & S_IFMT == S_IFDIR else {
            throw FileSystemEventHistoryError.targetIsNotDirectory
        }

        var fileSystemStats = statfs()
        let statFSResult = targetURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return statfs(path, &fileSystemStats)
        }
        guard statFSResult == 0 else {
            throw FileSystemEventHistoryError.targetUnavailable
        }
        guard fileSystemStats.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileSystemEventHistoryError.nonLocalVolume
        }

        guard let volumeUUID = FSEventsCopyUUIDForDevice(targetStat.st_dev),
              let volumeUUIDString = CFUUIDCreateString(nil, volumeUUID) as String? else {
            throw FileSystemEventHistoryError.volumeUUIDUnavailable
        }

        let targetPath = targetURL.path
        // `statfs("/")` reports the sealed system volume mounted at "/", but
        // `stat("/")` — and thus the FSEvents device — is the Data volume, so
        // events are reported relative to the Data root. Pin the mount point
        // to the Data volume for a root scan; every firmlinked target already
        // resolves to the Data mount through statfs.
        let mountPoint: String
        if targetPath == "/" {
            mountPoint = FirmlinkPathTranslator.dataVolumeMountPoint
        } else {
            mountPoint = Self.mountName(from: &fileSystemStats)
        }
        let relativeTargetPath = firmlinkTranslator.relativePath(
            forTarget: targetPath,
            mountPoint: mountPoint
        )

        return VolumeContext(
            deviceID: targetStat.st_dev,
            uuid: volumeUUIDString,
            mountPoint: mountPoint,
            relativeTargetPath: relativeTargetPath
        )
    }

    private static func mountName(from stats: inout statfs) -> String {
        withUnsafePointer(to: &stats.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private static func currentOSBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? ""
        }
    }
}

private nonisolated let neodiskFSEventHistoryCallback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
    guard let callbackInfo else { return }
    let collector = Unmanaged<FSEventHistoryCollector>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    collector.receive(
        eventCount: eventCount,
        relativePaths: paths,
        rawFlags: eventFlags,
        eventIDs: eventIDs
    )
}

/// Accumulates one replay's events and hands them back through a single
/// checked continuation. Resumes on exactly one of: HistoryDone (success),
/// cancellation, the replay deadline, or the event budget being exceeded —
/// `finish` is idempotent, so whichever fires first wins.
private final class FSEventHistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let since: FSEventsCheckpoint
    private let through: FSEventsCheckpoint
    private let mountPoint: String
    private let firmlinkTranslator: FirmlinkPathTranslator
    private let eventBudget: Int
    private var events: [FileSystemChangeEvent] = []
    private var rawEventCount = 0
    private var continuation: CheckedContinuation<FileSystemEventHistory, Error>?
    private var completion: Result<FileSystemEventHistory, Error>?

    init(
        since: FSEventsCheckpoint,
        through: FSEventsCheckpoint,
        mountPoint: String,
        firmlinkTranslator: FirmlinkPathTranslator,
        eventBudget: Int
    ) {
        self.since = since
        self.through = through
        self.mountPoint = mountPoint
        self.firmlinkTranslator = firmlinkTranslator
        self.eventBudget = eventBudget
    }

    func value() async throws -> FileSystemEventHistory {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completion {
                lock.unlock()
                continuation.resume(with: completion)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func timeOut() {
        finish(.failure(FileSystemEventHistoryError.historyReplayTimedOut))
    }

    func receive(
        eventCount: Int,
        relativePaths: UnsafePointer<UnsafePointer<CChar>>,
        rawFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        var sawHistoryDone = false
        var received: [FileSystemChangeEvent] = []
        received.reserveCapacity(eventCount)

        for index in 0..<eventCount {
            let mappedFlags = Self.flags(from: rawFlags[index])
            if mappedFlags.contains(.historyDone) {
                sawHistoryDone = true
                continue
            }

            let eventID = eventIDs[index]
            // RootChanged carries event ID 0 and must never be filtered out.
            guard mappedFlags.contains(.rootChanged) ||
                    (eventID > since.eventID && eventID <= through.eventID) else {
                continue
            }

            let relativePath = String(cString: relativePaths[index])
            let absolutePath = firmlinkTranslator.absolutePath(
                forEventRelativePath: relativePath,
                mountPoint: mountPoint
            )
            received.append(FileSystemChangeEvent(
                path: absolutePath,
                eventID: eventID,
                flags: mappedFlags
            ))
        }

        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        rawEventCount += eventCount
        if rawEventCount > eventBudget {
            lock.unlock()
            finish(.failure(FileSystemEventHistoryError.eventBudgetExceeded))
            return
        }
        events.append(contentsOf: received)
        let history = sawHistoryDone ? FileSystemEventHistory(events: events) : nil
        lock.unlock()

        if let history {
            finish(.success(history))
        }
    }

    private func finish(_ result: Result<FileSystemEventHistory, Error>) {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        completion = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func flags(from rawValue: FSEventStreamEventFlags) -> FileSystemEventFlags {
        var flags: FileSystemEventFlags = []
        func map(_ source: Int, _ destination: FileSystemEventFlags) {
            if rawValue & UInt32(source) != 0 {
                flags.insert(destination)
            }
        }

        map(kFSEventStreamEventFlagMustScanSubDirs, .mustScanSubdirectories)
        map(kFSEventStreamEventFlagUserDropped, .userDropped)
        map(kFSEventStreamEventFlagKernelDropped, .kernelDropped)
        map(kFSEventStreamEventFlagEventIdsWrapped, .eventIDsWrapped)
        map(kFSEventStreamEventFlagRootChanged, .rootChanged)
        map(kFSEventStreamEventFlagMount, .volumeMounted)
        map(kFSEventStreamEventFlagUnmount, .volumeUnmounted)
        map(kFSEventStreamEventFlagHistoryDone, .historyDone)
        map(kFSEventStreamEventFlagItemIsDir, .itemIsDirectory)
        map(kFSEventStreamEventFlagItemCreated, .itemCreated)
        map(kFSEventStreamEventFlagItemRemoved, .itemRemoved)
        map(kFSEventStreamEventFlagItemRenamed, .itemRenamed)
        return flags
    }
}

/// Idempotent teardown of a single transient stream. Stop → detach queue →
/// invalidate → release, guarded so repeated calls (deadline plus the awaiting
/// task's `defer`) are harmless.
private final class FSEventStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(stream: FSEventStreamRef) {
        self.stream = stream
    }

    func stop() {
        lock.lock()
        guard let stream else {
            lock.unlock()
            return
        }
        self.stream = nil
        lock.unlock()

        FSEventStreamStop(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
