import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// `.serialized` only serializes tests within one suite; sibling scan suites otherwise pile onto the main actor
/// and starve each other's waits. Lightweight suites stay top-level and parallel.
@Suite(.serialized) enum ScanTimingSuites {}

/// removePersistentDomain alone makes cfprefsd persist an empty domain, leaving a plist per run; delete the file.
func removeTestDefaultsSuite(_ defaults: UserDefaults, named suiteName: String) {
    defaults.removePersistentDomain(forName: suiteName)
    defaults.synchronize()
    let plist = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: plist)
}

func makeTestTarget(_ path: String, kind: ScanTargetKind = .folder) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: kind)
}

func makeTestFileNode(
    id: String,
    name: String,
    size: Int64 = 1,
    unduplicatedAllocatedSize: Int64? = nil,
    lastModified: Date? = nil,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        unduplicatedAllocatedSize: unduplicatedAllocatedSize,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: lastModified,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

func makeTestDirectoryNode(
    id: String,
    name: String,
    children: [FileNodeRecord],
    isPackage: Bool = false,
    isAccessible: Bool = true,
    fileIdentity: FileIdentity? = nil,
    linkCount: UInt64 = 1
) -> FileNodeRecord {
    FileNodeRecord.directory(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        children: children,
        lastModified: nil,
        fileIdentity: fileIdentity,
        linkCount: linkCount,
        isPackage: isPackage,
        isAccessible: isAccessible
    )
}

func makeTestSnapshot(
    target: ScanTarget? = nil,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = [],
    startedAt: Date = Date(),
    finishedAt: Date = Date()
) -> ScanSnapshot {
    ScanSnapshot(
        target: target ?? ScanTarget(url: root.url),
        treeStore: store,
        startedAt: startedAt,
        finishedAt: finishedAt,
        scanWarnings: warnings,
        aggregateStats: store.aggregateStats,
        isComplete: true
    )
}

// MARK: - Controlled scan stream

struct ControlledScanRequest {
    let target: ScanTarget
    let options: ScanOptions
}

/// Tests yield events per scan index instead of scanning disk.
final class ControlledScanService: ScanEventStreaming, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<ScanProgressEvent, Error>.Continuation

    private let lock = NSLock()
    private var continuations: [Continuation] = []
    private var storedRequests: [ControlledScanRequest] = []
    private var storedTerminationCount = 0

    var requests: [ControlledScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    var terminationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTerminationCount
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations.append(continuation)
            storedRequests.append(ControlledScanRequest(target: target, options: options))
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.storedTerminationCount += 1
                self.lock.unlock()
            }
        }
    }

    func yield(_ event: ScanProgressEvent, scanIndex: Int) {
        continuation(at: scanIndex)?.yield(event)
    }

    func finish(scanIndex: Int, throwing error: Error? = nil) {
        continuation(at: scanIndex)?.finish(throwing: error)
    }

    private func continuation(at index: Int) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.indices.contains(index) else { return nil }
        return continuations[index]
    }
}

// MARK: - Driving the coordinator directly

/// Wires hooks exactly as ScanSessionModel does, so coordinator tests drive the display the production way.
@MainActor
private func makeCoordinatorSession(
    _ coordinator: ScanCoordinator,
    target: ScanTarget,
    options: ScanOptions,
    kind: ScanSession.Kind,
    showsStandInWhileScanning: Bool,
    baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil,
    refreshBaseline: ScanSnapshot? = nil
) -> ScanSession {
    let session = ScanSession(
        target: target,
        options: options,
        kind: kind,
        service: coordinator.scanService,
        baselineProvider: baselineProvider,
        showsStandInWhileScanning: showsStandInWhileScanning,
        refreshBaseline: refreshBaseline,
        progress: ScanProgressState(),
        progressThrottleDuration: coordinator.progressThrottleDuration
    )
    session.onSnapshotUpdate = { coordinator.showDisplayedPartial(from: $0) }
    session.onCompletion = { coordinator.settleDisplayedCompletion(from: $0) }
    return session
}

/// Starts a cold live scan on `coordinator`, mirroring ScanSessionModel.
@MainActor
@discardableResult
func attachLiveScan(
    _ coordinator: ScanCoordinator,
    target: ScanTarget,
    options: ScanOptions = ScanOptions()
) -> ScanSession {
    let session = makeCoordinatorSession(
        coordinator, target: target, options: options,
        kind: .fresh, showsStandInWhileScanning: false
    )
    coordinator.attach(session, mode: .live, displaying: session.latestSnapshot)
    session.start()
    return session
}

/// Starts a refresh-behind-cache scan on `coordinator`, mirroring
/// ScanSessionModel's retention of a same-target complete snapshot.
@MainActor
@discardableResult
func attachRefreshScan(
    _ coordinator: ScanCoordinator,
    target: ScanTarget,
    options: ScanOptions = ScanOptions(),
    baselineProvider: (@Sendable () async -> ScanSnapshot?)? = nil
) -> ScanSession {
    let retained = coordinator.snapshot?.isComplete == true
        && coordinator.snapshot?.target.id == target.id
        ? coordinator.snapshot
        : coordinator.recentSnapshot(forTargetID: target.id)
    let effectiveBaselineProvider = retained.map { r in { @Sendable in r } } ?? baselineProvider
    let session = makeCoordinatorSession(
        coordinator, target: target, options: options,
        kind: effectiveBaselineProvider == nil ? .fresh : .refresh,
        showsStandInWhileScanning: true,
        baselineProvider: effectiveBaselineProvider,
        refreshBaseline: retained
    )
    coordinator.attach(
        session,
        mode: .refreshBehindCache(scanDate: retained.map { $0.finishedAt ?? $0.startedAt }),
        displaying: retained
    )
    session.start()
    return session
}

// MARK: - Deterministic persistence await

/// Awaits the persist seam instead of polling: a background completion can starve arbitrarily long under the
/// parallel bundle, and the seam has no deadline to miss.
@MainActor
func awaitSnapshotPersist(
    on model: NeodiskViewModel,
    of target: ScanTarget,
    trigger: () -> Void
) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        model.session.onSnapshotPersistedForTesting = { snapshot in
            guard snapshot.target.id == target.id else { return }
            // Resume once, then unhook so a later persist can't fire again.
            model.session.onSnapshotPersistedForTesting = nil
            continuation.resume()
        }
        trigger()
    }
}

// MARK: - Eventual-state assertions

/// The default timeout has slack because the bundle runs suites in parallel; it costs nothing on the happy path.
@MainActor
func waitUntilAsync(
    _ description: String,
    timeout: TimeInterval = 5,
    condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() >= deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    condition: () -> Bool
) async throws {
    try await waitUntilAsync(description, timeout: timeout, condition: condition)
}

/// Deterministic SplitMix64 for randomized equivalence tests, so a failure
/// reproduces from its seed.
struct SeededTestGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
