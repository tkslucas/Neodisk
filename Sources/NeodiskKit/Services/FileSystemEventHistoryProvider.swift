// Reads the fseventsd journal through one transient stream per call, never a persistent watcher. CoreServices
// stays confined here: events leave as plain `FileSystemChangeEvent`s.

#if canImport(CoreServices)
import CoreServices
import Darwin
import Dispatch
import Foundation

struct DarwinFileSystemEventHistoryProvider: FileSystemEventHistoryProviding {
    private let latency: CFTimeInterval
    /// Bounds the wait on a failed incremental gamble: at ~50k events/s, 3s covers weeks of churn, and a stalled
    /// fseventsd costs 3s, not 15.
    private let replayTimeout: DispatchTimeInterval
    /// A memory bound on distinct paths (repeats coalesce); wall-clock is `replayTimeout`'s job.
    private let eventBudget: Int
    private let firmlinkTranslator: FirmlinkPathTranslator

    init(
        latency: CFTimeInterval = 0.05,
        replayTimeout: DispatchTimeInterval = .seconds(3),
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
        // Device streams share one host-global counter, so this is valid and fresh, unlike the before-time
        // lookup, which lags live events by minutes and silently emptied recent windows.
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
            targetPath: target.url.standardizedFileURL.path,
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
        // Not FullHistory: coalesced older chunks just widen the rescan (events are only hints), and full
        // granular history only slows the drain.
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
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

        // Resumes even if HistoryDone never arrives; idempotent with the other finish paths.
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
        /// For a `/` target this is the Data volume mount, since the root namespace's `st_dev` is the Data device.
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
        // statfs("/") reports the sealed system volume, but stat("/"), and so FSEvents, uses the Data volume.
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

/// Resumes once on HistoryDone, cancellation, deadline or budget, whichever comes first. Events coalesce per
/// path (order doesn't matter to the planner), so only distinct paths count against the budget.
final class FSEventHistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let since: FSEventsCheckpoint
    private let through: FSEventsCheckpoint
    private let mountPoint: String
    private let targetPath: String
    private let firmlinkTranslator: FirmlinkPathTranslator
    private let eventBudget: Int
    private var eventsByPath: [String: FileSystemChangeEvent] = [:]
    private var continuation: CheckedContinuation<FileSystemEventHistory, Error>?
    private var completion: Result<FileSystemEventHistory, Error>?

    init(
        since: FSEventsCheckpoint,
        through: FSEventsCheckpoint,
        mountPoint: String,
        targetPath: String,
        firmlinkTranslator: FirmlinkPathTranslator,
        eventBudget: Int
    ) {
        self.since = since
        self.through = through
        self.mountPoint = mountPoint
        self.targetPath = targetPath
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
            // Escalation sentinels can carry ID 0 or fall outside the window; dropping one would make a
            // truncated replay look clean.
            guard mappedFlags.demandsFullScan ||
                    (eventID > since.eventID && eventID <= through.eventID) else {
                continue
            }

            let relativePath = String(cString: relativePaths[index])
            let absolutePath = firmlinkTranslator.absolutePath(
                forEventRelativePath: relativePath,
                mountPoint: mountPoint,
                targetPath: targetPath
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
        for event in received {
            if let existing = eventsByPath[event.path] {
                eventsByPath[event.path] = FileSystemChangeEvent(
                    path: event.path,
                    eventID: max(existing.eventID, event.eventID),
                    flags: existing.flags.union(event.flags)
                )
            } else {
                eventsByPath[event.path] = event
            }
        }
        if eventsByPath.count > eventBudget {
            lock.unlock()
            finish(.failure(FileSystemEventHistoryError.eventBudgetExceeded))
            return
        }
        let history = sawHistoryDone
            ? FileSystemEventHistory(events: eventsByPath.values.sorted { $0.eventID < $1.eventID })
            : nil
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
        map(kFSEventStreamEventFlagItemIsHardlink, .itemIsHardLink)
        map(kFSEventStreamEventFlagItemIsLastHardlink, .itemIsLastHardLink)
        return flags
    }
}

/// Guarded so repeated calls (deadline plus the awaiting task's `defer`) are harmless.
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

#endif
