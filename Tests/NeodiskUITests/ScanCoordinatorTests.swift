import Combine
import Testing
import Foundation
import NeodiskKit
@testable import NeodiskUI

@Suite(.serialized) struct ScanCoordinatorTests {
    @MainActor
    @Test func testStartAndFinishScanState() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/root")
        let snapshot = makeCoordinatorSnapshot(target: target)

        coordinator.startScan(target, options: ScanOptions())

        #expect(coordinator.phase == .scanning)
        #expect(coordinator.selectedTarget == target)
        #expect(coordinator.snapshot == nil)
        #expect(coordinator.fileTreeStore == nil)
        #expect(service.requests.map(\.target) == [target])

        service.yield(.progress(makeCoordinatorMetrics(path: "/scan/root/a.txt", filesVisited: 1)), scanIndex: 0)
        try await waitUntil("initial progress") {
            coordinator.scanMetrics.currentPath == "/scan/root/a.txt"
        }

        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("finished scan") {
            coordinator.phase == .displaying
        }

        #expect(coordinator.snapshot?.target == target)
        #expect(coordinator.fileTreeStore?.root.id == snapshot.root.id)
        #expect(abs((coordinator.scanMetrics.progressFraction) - (1)) <= 0.0001)
        #expect(!(coordinator.canStopScan))
        #expect(coordinator.canRescan)
    }

    @MainActor
    @Test func testRestoreCompletedSnapshotDisplaysWithoutScanRequest() {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/cached")
        let snapshot = makeCoordinatorSnapshot(target: target)

        coordinator.restoreCompletedSnapshot(snapshot)

        #expect(service.requests.isEmpty)
        #expect(coordinator.phase == .displaying)
        #expect(coordinator.selectedTarget == target)
        #expect(coordinator.snapshot?.target == target)
        #expect(coordinator.fileTreeStore?.root.id == snapshot.root.id)
        #expect(abs((coordinator.scanMetrics.progressFraction) - (1)) <= 0.0001)
    }

    @MainActor
    @Test func testStoppingScanCancelsAndIgnoresLateEvents() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/cancel")

        coordinator.startScan(target, options: ScanOptions())
        coordinator.stopScan()

        try await waitUntil("stream cancellation") {
            service.terminationCount > 0
        }

        service.yield(.finished(makeCoordinatorSnapshot(target: target)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await Task.sleep(for: .milliseconds(40))

        #expect(coordinator.phase == .idle)
        #expect(coordinator.snapshot == nil)
        #expect(coordinator.fileTreeStore == nil)
        #expect(!(coordinator.canStopScan))
    }

    @MainActor
    @Test func testStaleScanEventsCannotReplaceNewerScan() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let firstTarget = makeCoordinatorTarget("/scan/first")
        let secondTarget = makeCoordinatorTarget("/scan/second")
        let firstSnapshot = makeCoordinatorSnapshot(target: firstTarget)
        let secondSnapshot = makeCoordinatorSnapshot(target: secondTarget)

        coordinator.startScan(firstTarget, options: ScanOptions())
        coordinator.startScan(secondTarget, options: ScanOptions())

        #expect(service.requests.map(\.target) == [firstTarget, secondTarget])

        service.yield(.finished(firstSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.phase == .scanning)
        #expect(coordinator.snapshot == nil)

        service.yield(.finished(secondSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)

        try await waitUntil("second scan finished") {
            coordinator.phase == .displaying
        }

        #expect(coordinator.selectedTarget == secondTarget)
        #expect(coordinator.snapshot?.target == secondTarget)
    }

    @MainActor
    @Test func testSwitchingBackToRecentTargetDisplaysInstantlyFromMemory() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let firstTarget = makeCoordinatorTarget("/scan/first")
        let secondTarget = makeCoordinatorTarget("/scan/second")
        let firstSnapshot = makeCoordinatorSnapshot(target: firstTarget)
        let secondSnapshot = makeCoordinatorSnapshot(target: secondTarget)

        // Scan first, then second: first's snapshot leaves the screen but
        // stays remembered in memory.
        coordinator.startScan(firstTarget, options: ScanOptions())
        service.yield(.finished(firstSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("first displayed") { coordinator.phase == .displaying }

        coordinator.startScan(secondTarget, options: ScanOptions())
        service.yield(.finished(secondSnapshot), scanIndex: 1)
        service.finish(scanIndex: 1)
        try await waitUntil("second displayed") { coordinator.snapshot?.target == secondTarget }

        // Switching back shows first's map synchronously — no decode, no
        // transition screen — with the refresh scan running behind it.
        coordinator.startRefreshScan(firstTarget, options: ScanOptions())
        #expect(coordinator.snapshot?.id == firstSnapshot.id)
        #expect(coordinator.phase == .scanning)
        #expect(coordinator.suppressesPartialEvents)

        // Forgetting the target removes the instant-display copy.
        coordinator.forgetRecentSnapshot(forTargetID: secondTarget.id)
        #expect(coordinator.recentSnapshot(forTargetID: secondTarget.id) == nil)
    }

    @MainActor
    @Test func testProgressEventsAreThrottledToLatestPendingMetrics() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(90))
        var publishedPaths: [String] = []
        let cancellable = coordinator.progress.$metrics
            .sink { metrics in
                guard !metrics.currentPath.isEmpty else { return }
                publishedPaths.append(metrics.currentPath)
            }

        coordinator.startScan(makeCoordinatorTarget("/scan/progress"), options: ScanOptions())

        service.yield(.progress(makeCoordinatorMetrics(path: "first", filesVisited: 1)), scanIndex: 0)
        service.yield(.progress(makeCoordinatorMetrics(path: "second", filesVisited: 2)), scanIndex: 0)
        service.yield(.progress(makeCoordinatorMetrics(path: "third", filesVisited: 3)), scanIndex: 0)

        // "first" publishes immediately; "second" is superseded by "third" within the
        // throttle window, so the single trailing publish is "third". Assert on the
        // eventual state rather than a fixed-delay snapshot to avoid timing races.
        try await waitUntil("throttled trailing progress publish", timeout: 1.5) {
            publishedPaths == ["first", "third"]
        }

        #expect(publishedPaths == ["first", "third"])
        #expect(!publishedPaths.contains("second"))
        coordinator.stopScan()
        cancellable.cancel()
    }

    @MainActor
    @Test func testFinishedScanFlushesPendingThrottledProgress() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(250))
        let target = makeCoordinatorTarget("/scan/finish-flush")
        let snapshot = makeCoordinatorSnapshot(target: target)
        var publishedPaths: [String] = []
        let cancellable = coordinator.progress.$metrics
            .sink { metrics in
                guard !metrics.currentPath.isEmpty else { return }
                publishedPaths.append(metrics.currentPath)
            }

        coordinator.startScan(target, options: ScanOptions())
        service.yield(.progress(makeCoordinatorMetrics(path: "first", filesVisited: 1)), scanIndex: 0)

        try await waitUntil("first progress publish") {
            publishedPaths == ["first"]
        }

        service.yield(.progress(makeCoordinatorMetrics(path: "pending-final", filesVisited: 2)), scanIndex: 0)
        service.yield(.finished(snapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        try await waitUntil("finished scan with flushed progress") {
            coordinator.phase == .displaying
        }

        #expect(coordinator.scanMetrics.currentPath == "pending-final")
        #expect(abs((coordinator.scanMetrics.progressFraction) - (1)) <= 0.0001)
        #expect(publishedPaths.contains("pending-final"))
        cancellable.cancel()
    }

    @MainActor
    @Test func testProgressMetricsDoNotPublishCoordinatorChanges() {
        let coordinator = ScanCoordinator()
        nonisolated(unsafe) var coordinatorChangeCount = 0
        var progressChangeCount = 0

        // Observe every stored observable property on the coordinator the
        // way a SwiftUI view body would; a metrics update must not
        // invalidate any of them.
        withObservationTracking {
            _ = coordinator.phase
            _ = coordinator.snapshot
            _ = coordinator.selectedTarget
            _ = coordinator.completedScanSnapshot
            _ = coordinator.scanErrorMessage
            _ = coordinator.expandingNodeID
            _ = coordinator.displaySource
        } onChange: {
            coordinatorChangeCount += 1
        }
        let progressCancellable = coordinator.progress.$metrics
            .dropFirst()
            .sink { _ in
                progressChangeCount += 1
            }

        var metrics = ScanMetrics()
        metrics.currentPath = "/scan/progress-only"
        metrics.filesVisited = 42
        coordinator.scanMetrics = metrics

        #expect(progressChangeCount == 1)
        #expect(coordinatorChangeCount == 0)
        withExtendedLifetime(progressCancellable) {}
    }

    @MainActor
    @Test func testExpandingSummarizedNodeReplacesSubtreeAndMergesWarnings() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let summarizedNode = makeCoordinatorSummarizedDirectoryNode(id: "/root/cache", name: "cache", size: 300)
        let sibling = makeTestFileNode(id: "/root/readme.txt", name: "readme.txt", size: 50)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [summarizedNode, sibling])
        let baseStore = FileTreeStore(root: root, childrenByID: [root.id: [summarizedNode, sibling]])
        let existingWarning = ScanWarning(path: "/root/cache", message: "original", category: .fileSystem)
        let baseSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget("/root"),
            root: root,
            store: baseStore,
            warnings: [existingWarning]
        )
        coordinator.replaceCurrentSnapshot(baseSnapshot)

        let expandedFile = makeTestFileNode(id: "/root/cache/item.txt", name: "item.txt", size: 125)
        let expandedRoot = makeTestDirectoryNode(id: summarizedNode.id, name: "cache", children: [expandedFile])
        let expandedStore = FileTreeStore(root: expandedRoot, childrenByID: [expandedRoot.id: [expandedFile]])
        let expansionWarning = ScanWarning(path: expandedFile.id, message: "expanded", category: .permissionDenied)
        let expandedSnapshot = makeCoordinatorSnapshot(
            target: makeCoordinatorTarget(summarizedNode.id),
            root: expandedRoot,
            store: expandedStore,
            warnings: [expansionWarning]
        )

        var expansionResult: ScanExpansionResult?
        let expansionTask = Task {
            expansionResult = await coordinator.expandNodeContents(
                summarizedNode,
                options: ScanOptions(includeHiddenFiles: true, autoSummarizeDirectories: false)
            )
        }
        try await waitUntil("expansion started") {
            coordinator.expandingNodeID == summarizedNode.id
        }

        #expect(service.requests.last?.target == ScanTarget(url: summarizedNode.url))
        #expect(service.requests.last?.options.autoSummarizeDirectories == false)
        #expect(coordinator.expandingNodeID == summarizedNode.id)

        service.yield(.finished(expandedSnapshot), scanIndex: 0)
        service.finish(scanIndex: 0)

        await expansionTask.value

        guard case .expanded(let replacementRootID) = expansionResult else {
            Issue.record("Expected expansion to complete with replacement root ID.")
            return
        }

        let updatedSnapshot = try #require(coordinator.snapshot)
        let updatedNode = try #require(updatedSnapshot.treeStore.node(id: summarizedNode.id))
        #expect(replacementRootID == summarizedNode.id)
        #expect(!(updatedNode.isAutoSummarized))
        #expect(updatedSnapshot.treeStore.children(of: summarizedNode.id).map(\.id) == [expandedFile.id])
        #expect(updatedSnapshot.scanWarnings.map(\.path) == [existingWarning.path, expansionWarning.path])
        #expect(coordinator.fileTreeStore?.root.id == root.id)
        #expect(coordinator.expandingNodeID == nil)
    }

    @MainActor
    @Test func testRefreshScanSuppressesPartialsUntilCachedSnapshotArrives() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/refresh")
        let cached = makeCoordinatorSnapshot(target: target)

        coordinator.startRefreshScan(target, options: ScanOptions())
        #expect(coordinator.phase == .scanning)
        #expect(coordinator.snapshot == nil)

        // Partial trees are dropped while the cached snapshot stands in.
        service.yield(.partial(cached.treeStore), scanIndex: 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.snapshot == nil)

        coordinator.displayCachedSnapshot(cached)
        #expect(coordinator.phase == .scanning)
        #expect(coordinator.snapshot?.id == cached.id)
        #expect(coordinator.snapshot?.isComplete == true)
        #expect(coordinator.displayedCachedScanDate == cached.finishedAt)

        let partialFile = makeTestFileNode(id: target.id + "/partial.txt", name: "partial.txt", size: 5)
        let partialRoot = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [partialFile])
        service.yield(
            .partial(FileTreeStore(root: partialRoot, childrenByID: [partialRoot.id: [partialFile]])),
            scanIndex: 0
        )
        try await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.snapshot?.id == cached.id)

        // The fresh finished snapshot replaces the cached one.
        let fresh = makeCoordinatorSnapshot(target: target)
        service.yield(.finished(fresh), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("refresh scan finished") {
            coordinator.phase == .displaying
        }
        #expect(coordinator.snapshot?.id == fresh.id)
        #expect(coordinator.displayedCachedScanDate == nil)
    }

    @MainActor
    @Test func testRefreshScanRetainsCurrentCompleteSnapshotOfSameTarget() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/rescan")
        let current = makeCoordinatorSnapshot(target: target)
        coordinator.restoreCompletedSnapshot(current)

        coordinator.startRefreshScan(target, options: ScanOptions())

        #expect(coordinator.phase == .scanning)
        #expect(coordinator.snapshot?.id == current.id)
        #expect(coordinator.displayedCachedScanDate == current.finishedAt)

        // Stopping the refresh keeps the retained snapshot on screen.
        coordinator.stopScan()
        #expect(coordinator.phase == .displaying)
        #expect(coordinator.snapshot?.id == current.id)
    }

    @MainActor
    @Test func testCachedSnapshotCannotClobberFinishedOrRetargetedScan() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/late-cache")
        let cached = makeCoordinatorSnapshot(target: target)
        let fresh = makeCoordinatorSnapshot(target: target)

        coordinator.startRefreshScan(target, options: ScanOptions())
        service.yield(.finished(fresh), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("fresh scan finished") {
            coordinator.phase == .displaying
        }

        // A slow cache decode arriving after the fresh finish is ignored.
        coordinator.displayCachedSnapshot(cached)
        #expect(coordinator.snapshot?.id == fresh.id)

        // And one arriving after the user switched targets is ignored too.
        let otherTarget = makeCoordinatorTarget("/scan/other")
        coordinator.startRefreshScan(otherTarget, options: ScanOptions())
        coordinator.displayCachedSnapshot(cached)
        #expect(coordinator.snapshot == nil)
        coordinator.stopScan()
    }

    @MainActor
    @Test func testAbandoningCachedDisplayResumesPartialStreaming() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeCoordinatorTarget("/scan/abandon")

        coordinator.startRefreshScan(target, options: ScanOptions())

        // Abandoning for a different target changes nothing.
        coordinator.abandonCachedSnapshotDisplay(forTargetID: "/scan/other")
        let droppedPartial = makeCoordinatorSnapshot(target: target)
        service.yield(.partial(droppedPartial.treeStore), scanIndex: 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(coordinator.snapshot == nil)

        // Abandoning for the scanned target lets partials through again.
        coordinator.abandonCachedSnapshotDisplay(forTargetID: target.id)
        service.yield(.partial(droppedPartial.treeStore), scanIndex: 0)
        try await waitUntil("partial tree published") {
            coordinator.snapshot != nil
        }
        #expect(coordinator.snapshot?.isComplete == false)
        coordinator.stopScan()
    }

    @MainActor
    @Test func testRemovingLargeSubtreeFromCurrentSnapshotUsesTransformService() async throws {
        let service = ControlledScanService()
        let transformService = RecordingSnapshotTransformService()
        let coordinator = ScanCoordinator(
            scanService: service,
            snapshotTransformService: transformService,
            progressThrottleDuration: .milliseconds(40)
        )
        let target = makeCoordinatorTarget("/root")
        let removedFiles = (0..<600).map { index in
            makeTestFileNode(
                id: "/root/cache/file-\(index).dat",
                name: "file-\(index).dat",
                size: 1
            )
        }
        let removedDirectory = makeTestDirectoryNode(id: "/root/cache", name: "cache", children: removedFiles)
        let sibling = makeTestFileNode(id: "/root/readme.txt", name: "readme.txt", size: 25)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [removedDirectory, sibling])
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: [removedDirectory, sibling],
            removedDirectory.id: removedFiles,
        ])
        let snapshot = makeCoordinatorSnapshot(target: target, root: root, store: store)
        coordinator.replaceCurrentSnapshot(snapshot)

        let didRemove = await coordinator.removeNodeFromCurrentSnapshot(id: removedDirectory.id)
        let recordedRemovingNodeIDs = await transformService.recordedRemovingNodeIDs()

        #expect(didRemove)
        #expect(recordedRemovingNodeIDs == [removedDirectory.id])
        #expect(coordinator.snapshot?.treeStore.node(id: removedDirectory.id) == nil)
        #expect(coordinator.snapshot?.aggregateStats.fileCount == 1)
        #expect(coordinator.fileTreeStore?.children(of: root.id).map(\.id) == [sibling.id])
    }

}

private struct ControlledScanRequest {
    let target: ScanTarget
    let options: ScanOptions
}

private actor RecordingSnapshotTransformService: ScanSnapshotTransforming {
    private var removingNodeIDs: [String] = []

    func recordedRemovingNodeIDs() -> [String] {
        removingNodeIDs
    }

    func replacingNode(
        in snapshot: ScanSnapshot,
        id targetID: String,
        with replacement: FileTreeStore,
        additionalWarnings: [ScanWarning]
    ) async throws -> ScanSnapshot? {
        try snapshot.replacingNode(
            id: targetID,
            with: replacement,
            additionalWarnings: additionalWarnings,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func removingNode(
        in snapshot: ScanSnapshot,
        id targetID: String
    ) async throws -> ScanSnapshot? {
        removingNodeIDs.append(targetID)
        return try snapshot.removingNode(
            id: targetID,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func scopedSnapshot(
        _ snapshot: ScanSnapshot,
        to target: ScanTarget
    ) async throws -> ScanSnapshot? {
        try snapshot.scoped(
            to: target,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }
}

private final class ControlledScanService: ScanEventStreaming, @unchecked Sendable {
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


@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}

private func makeCoordinatorTarget(_ path: String) -> ScanTarget {
    ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
}


private func makeCoordinatorMetrics(path: String, filesVisited: Int) -> ScanMetrics {
    var metrics = ScanMetrics()
    metrics.currentPath = path
    metrics.filesVisited = filesVisited
    metrics.bytesDiscovered = Int64(filesVisited)
    metrics.progressFraction = min(Double(filesVisited) / 10, 0.95)
    return metrics
}

private func makeCoordinatorSnapshot(target: ScanTarget) -> ScanSnapshot {
    let file = makeTestFileNode(id: target.url.appendingPathComponent("file.txt").path, name: "file.txt", size: 20)
    let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
    let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
    return makeCoordinatorSnapshot(target: target, root: root, store: store)
}

private func makeCoordinatorHomeSnapshot(
    target homeTarget: ScanTarget,
    downloadsTarget: ScanTarget,
    rootName: String
) -> ScanSnapshot {
    let downloadFile = makeTestFileNode(
        id: downloadsTarget.id + "/download.txt",
        name: "download.txt",
        size: 20
    )
    let siblingFile = makeTestFileNode(
        id: homeTarget.id + "/notes.txt",
        name: "notes.txt",
        size: 10
    )
    let downloadsNode = makeTestDirectoryNode(
        id: downloadsTarget.id,
        name: "Downloads",
        children: [downloadFile]
    )
    let homeRoot = makeTestDirectoryNode(
        id: homeTarget.id,
        name: rootName,
        children: [downloadsNode, siblingFile]
    )
    let homeStore = FileTreeStore(root: homeRoot, childrenByID: [
        homeRoot.id: [downloadsNode, siblingFile],
        downloadsNode.id: [downloadFile],
    ])
    return makeCoordinatorSnapshot(target: homeTarget, root: homeRoot, store: homeStore)
}

private func makeCoordinatorSnapshot(
    target: ScanTarget,
    root: FileNodeRecord,
    store: FileTreeStore,
    warnings: [ScanWarning] = []
) -> ScanSnapshot {
    makeTestSnapshot(
        target: target,
        root: root,
        store: store,
        warnings: warnings
    )
}

private func makeCoordinatorSummarizedDirectoryNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id, directoryHint: .isDirectory),
        name: name,
        isDirectory: true,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 12,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: true
    )
}
