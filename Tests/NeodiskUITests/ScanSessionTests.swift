import Combine
import Testing
import Foundation
import NeodiskKit
@testable import NeodiskUI

extension ScanTimingSuites {
@Suite(.serialized) struct ScanSessionTests {
    /// A partial tree is recorded on the session even while the coordinator
    /// suppresses it from the screen (the refresh-behind-cached path): the
    /// session always keeps the latest tree, the coordinator decides display.
    @MainActor
    @Test func testLatestPartialRetainedWhileDisplaySuppressed() async throws {
        let service = ControlledScanService()
        let coordinator = ScanCoordinator(scanService: service, progressThrottleDuration: .milliseconds(40))
        let target = makeTestTarget("/session/suppressed")

        // No cached snapshot, so the refresh suppresses partials with nothing
        // on screen.
        attachRefreshScan(coordinator, target: target)
        #expect(coordinator.suppressesPartialEvents)
        #expect(coordinator.snapshot == nil)

        let file = makeTestFileNode(id: target.id + "/p.txt", name: "p.txt", size: 5)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        service.yield(.partial(store), scanIndex: 0)

        try await waitUntil("partial recorded on the session") {
            coordinator.displayedSession?.latestSnapshot != nil
        }
        // Recorded on the session, still absent from the screen.
        #expect(coordinator.displayedSession?.latestSnapshot?.isComplete == false)
        #expect(coordinator.displayedSession?.latestSnapshot?.treeStore.root.id == root.id)
        #expect(coordinator.snapshot == nil)
        coordinator.stopScan()
    }

    /// Discovery counters never count down within a session even when a later
    /// progress event reports lower totals.
    @MainActor
    @Test func testProgressCountersNeverDecrease() async throws {
        let service = ControlledScanService()
        let progress = ScanProgressState()
        let session = makeSession(service: service, progress: progress, throttle: .zero)
        session.start()

        service.yield(.progress(metrics(path: "higher", filesVisited: 100)), scanIndex: 0)
        try await waitUntil("higher counters published") {
            progress.metrics.filesVisited == 100
        }

        service.yield(.progress(metrics(path: "lower", filesVisited: 40)), scanIndex: 0)
        try await waitUntil("later path published") {
            progress.metrics.currentPath == "lower"
        }

        #expect(progress.metrics.filesVisited == 100)
        #expect(progress.metrics.bytesDiscovered == 100)
        session.cancel()
    }

    /// Progress is throttled to the latest pending metrics: the first publishes
    /// immediately, an intermediate is superseded within the window, and only
    /// the trailing value follows.
    ///
    /// The throttle window is deliberately wide: the burst events are consumed
    /// off the async stream, so under a loaded machine the gap between
    /// consuming them can stretch — a window that dwarfs scheduler jitter is
    /// what keeps the coalescing (not the assertion) deterministic.
    @MainActor
    @Test func testThrottlePublishesLatestPending() async throws {
        let service = ControlledScanService()
        let progress = ScanProgressState()
        var publishedPaths: [String] = []
        let cancellable = progress.$metrics.sink { metrics in
            guard !metrics.currentPath.isEmpty else { return }
            publishedPaths.append(metrics.currentPath)
        }
        let session = makeSession(service: service, progress: progress, throttle: .milliseconds(500))
        session.start()

        service.yield(.progress(metrics(path: "first", filesVisited: 1)), scanIndex: 0)
        service.yield(.progress(metrics(path: "second", filesVisited: 2)), scanIndex: 0)
        service.yield(.progress(metrics(path: "third", filesVisited: 3)), scanIndex: 0)

        try await waitUntil("throttled trailing progress publish", timeout: 4) {
            publishedPaths == ["first", "third"]
        }
        #expect(!publishedPaths.contains("second"))
        session.cancel()
        cancellable.cancel()
    }

    /// A cancelled session ignores events that arrive after cancellation and
    /// never fires completion.
    @MainActor
    @Test func testCancelIgnoresLateEvents() async throws {
        let service = ControlledScanService()
        let target = makeTestTarget("/session/cancel")
        let session = makeSession(service: service, target: target, progress: ScanProgressState(), throttle: .zero)
        var completions = 0
        session.onCompletion = { _ in completions += 1 }
        session.start()

        session.cancel()
        #expect(session.state == .cancelled)

        let file = makeTestFileNode(id: target.id + "/f.txt", name: "f.txt", size: 20)
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        service.yield(.finished(makeTestSnapshot(target: target, root: root, store: store)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await Task.sleep(for: .milliseconds(40))

        #expect(session.state == .cancelled)
        #expect(session.latestSnapshot == nil)
        #expect(completions == 0)
    }

    // MARK: - Fixtures

    @MainActor
    private func makeSession(
        service: ControlledScanService,
        target: ScanTarget = makeTestTarget("/session/root"),
        progress: ScanProgressState,
        throttle: Duration
    ) -> ScanSession {
        ScanSession(
            target: target,
            options: ScanOptions(),
            kind: .fresh,
            service: service,
            progress: progress,
            progressThrottleDuration: throttle
        )
    }

    private func metrics(path: String, filesVisited: Int) -> ScanMetrics {
        var metrics = ScanMetrics()
        metrics.currentPath = path
        metrics.filesVisited = filesVisited
        metrics.bytesDiscovered = Int64(filesVisited)
        metrics.progressFraction = min(Double(filesVisited) / 10, 0.95)
        return metrics
    }
}

}
