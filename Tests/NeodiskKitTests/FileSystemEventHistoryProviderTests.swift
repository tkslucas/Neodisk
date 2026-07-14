import Foundation
import Testing
@testable import NeodiskKit

/// Exercises the real Darwin FSEvents provider against the machine's live
/// fseventsd journal. Serialized because the journal is process-global shared
/// state and these tests stand up transient streams; time-limited so a stalled
/// replay fails loud instead of hanging the suite.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileSystemEventHistoryProviderTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `history` with fresh `through` cutpoints until the expected path
    /// shows up or the deadline lapses. fseventsd journals asynchronously, so
    /// a change is not immediately replayable.
    private func waitForHistory(
        provider: DarwinFileSystemEventHistoryProvider,
        since: FSEventsCheckpoint,
        target: ScanTarget,
        deadline: Date,
        contains predicate: (FileSystemChangeEvent) -> Bool
    ) async throws -> FileSystemEventHistory? {
        var latest: FileSystemEventHistory?
        while Date() < deadline {
            let through = try provider.currentCheckpoint(for: target)
            let history = try await provider.history(since: since, through: through, target: target)
            latest = history
            if history.events.contains(where: predicate) {
                return history
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return latest
    }

    @Test func replaysCreatedRemovedAndModifiedSubtreePaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = DarwinFileSystemEventHistoryProvider()

        // If the machine has no journal for this volume the capture throws;
        // skip cleanly rather than failing.
        guard let since = try? provider.currentCheckpoint(for: target) else { return }

        // Mutate several subdirectories after the checkpoint: create, modify,
        // and delete, so the window has membership changes to replay.
        let alpha = root.appending(path: "alpha", directoryHint: .isDirectory)
        let beta = root.appending(path: "beta", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        let createdFile = alpha.appending(path: "one.txt")
        try Data("hello".utf8).write(to: createdFile)
        try Data("more".utf8).write(to: createdFile) // modify
        let doomed = beta.appending(path: "two.txt")
        try Data("bye".utf8).write(to: doomed)
        try FileManager.default.removeItem(at: doomed) // remove

        // Event paths, after firmlink normalization, are prefixed with the
        // target's own resolved path (the tree's namespace).
        let history = try await waitForHistory(
            provider: provider,
            since: since,
            target: target,
            deadline: Date().addingTimeInterval(10)
        ) { $0.path.hasPrefix(alpha.path) }

        let events = try #require(history).events
        #expect(events.contains { $0.path.hasPrefix(alpha.path) })
        #expect(events.contains { $0.path.hasPrefix(beta.path) })
        // Every surfaced path is absolute in the target's namespace, never a
        // raw Data-volume-relative or `/System/Volumes/Data/...` form.
        #expect(events.allSatisfy { $0.path.hasPrefix(root.path) })
        #expect(events.allSatisfy { !$0.path.hasPrefix("/System/Volumes/Data/") })
        // HistoryDone is a sentinel and must never surface as an event.
        #expect(events.allSatisfy { !$0.flags.contains(.historyDone) })
    }

    @Test func unchangedWindowReturnsEmptyWithoutStream() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = DarwinFileSystemEventHistoryProvider()

        guard let since = try? provider.currentCheckpoint(for: target) else { return }
        // through == since: the provider short-circuits with no replay.
        let history = try await provider.history(since: since, through: since, target: target)
        #expect(history.events.isEmpty)
    }

    @Test func replayReturnsPromptlyEvenWithShortDeadline() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = DarwinFileSystemEventHistoryProvider(replayTimeout: .milliseconds(500))

        guard let since = try? provider.currentCheckpoint(for: target) else { return }
        try Data("x".utf8).write(to: root.appending(path: "probe.txt"))
        let through = try provider.currentCheckpoint(for: target)

        // Must return (success or a thrown timeout), never deadlock. Reaching
        // this line at all is the assertion; the suite time limit is the net.
        _ = try? await provider.history(since: since, through: through, target: target)
    }

    // MARK: checkpoint validation (doctored checkpoints, no stream created)

    private func liveCheckpoint() throws -> (provider: DarwinFileSystemEventHistoryProvider, target: ScanTarget, root: URL, checkpoint: FSEventsCheckpoint)? {
        let root = try makeTemporaryDirectory()
        let target = ScanTarget(url: root)
        let provider = DarwinFileSystemEventHistoryProvider()
        guard let checkpoint = try? provider.currentCheckpoint(for: target) else {
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        return (provider, target, root, checkpoint)
    }

    @Test func volumeUUIDMismatchThrowsVolumeChanged() async throws {
        guard let live = try liveCheckpoint() else { return }
        defer { try? FileManager.default.removeItem(at: live.root) }
        let wrong = FSEventsCheckpoint(
            volumeUUID: "00000000-0000-0000-0000-000000000000",
            eventID: live.checkpoint.eventID,
            capturedAt: Date(),
            osBuild: live.checkpoint.osBuild
        )
        let through = FSEventsCheckpoint(
            volumeUUID: live.checkpoint.volumeUUID,
            eventID: live.checkpoint.eventID + 1,
            capturedAt: Date(),
            osBuild: live.checkpoint.osBuild
        )
        await #expect(throws: FileSystemEventHistoryError.volumeChanged) {
            _ = try await live.provider.history(since: wrong, through: through, target: live.target)
        }
    }

    @Test func rolledBackEventIDThrows() async throws {
        guard let live = try liveCheckpoint() else { return }
        defer { try? FileManager.default.removeItem(at: live.root) }
        let base = live.checkpoint
        let since = FSEventsCheckpoint(volumeUUID: base.volumeUUID, eventID: base.eventID, capturedAt: Date(), osBuild: base.osBuild)
        let through = FSEventsCheckpoint(volumeUUID: base.volumeUUID, eventID: base.eventID - 1, capturedAt: Date(), osBuild: base.osBuild)
        await #expect(throws: FileSystemEventHistoryError.eventIDRolledBack) {
            _ = try await live.provider.history(since: since, through: through, target: live.target)
        }
    }

    @Test func expiredCheckpointThrows() async throws {
        guard let live = try liveCheckpoint() else { return }
        defer { try? FileManager.default.removeItem(at: live.root) }
        let base = live.checkpoint
        let stale = FSEventsCheckpoint(
            volumeUUID: base.volumeUUID,
            eventID: base.eventID,
            capturedAt: Date().addingTimeInterval(-FSEventsCheckpoint.maxTrustedAge - 60),
            osBuild: base.osBuild
        )
        let through = FSEventsCheckpoint(volumeUUID: base.volumeUUID, eventID: base.eventID + 1, capturedAt: Date(), osBuild: base.osBuild)
        await #expect(throws: FileSystemEventHistoryError.checkpointExpired) {
            _ = try await live.provider.history(since: stale, through: through, target: live.target)
        }
    }

    @Test func osBuildMismatchThrows() async throws {
        guard let live = try liveCheckpoint() else { return }
        defer { try? FileManager.default.removeItem(at: live.root) }
        let base = live.checkpoint
        let since = FSEventsCheckpoint(volumeUUID: base.volumeUUID, eventID: base.eventID, capturedAt: Date(), osBuild: "BOGUS-BUILD")
        let through = FSEventsCheckpoint(volumeUUID: base.volumeUUID, eventID: base.eventID + 1, capturedAt: Date(), osBuild: "BOGUS-BUILD")
        await #expect(throws: FileSystemEventHistoryError.osBuildChanged) {
            _ = try await live.provider.history(since: since, through: through, target: live.target)
        }
    }

    @Test func missingTargetThrowsTargetUnavailable() async throws {
        let target = ScanTarget(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        let provider = DarwinFileSystemEventHistoryProvider()
        #expect(throws: FileSystemEventHistoryError.targetUnavailable) {
            _ = try provider.currentCheckpoint(for: target)
        }
    }
}
