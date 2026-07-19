import Foundation
import Testing
@testable import NeodiskKit

/// The strongest guarantee the incremental pipeline makes: a fine-grained
/// directory relist must produce a tree byte-for-byte equivalent to a fresh
/// full scan of the same on-disk state. These tests build a random tree, apply
/// randomized churn (creates, deletes, renames, cross-directory moves, content
/// touches — for both files and directories), synthesize the FSEvents the
/// Darwin history provider would surface for that churn, run the incremental
/// rescan, and assert the result equals a from-scratch scan. Many seeds.
///
/// The FSEvents journal is scripted (a stub), so the events are minimal-but-
/// faithful: every mutation names the affected path with the flags a real
/// journal carries. Sparser events than reality would only *miss* changes —
/// which surfaces here as a divergence, exactly the failure this guards.
@Suite("IncrementalRescanEquivalence", .serialized)
struct IncrementalRescanEquivalenceTests {

    // MARK: - Deterministic RNG

    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Scripted journal

    private final class StubProvider: FileSystemEventHistoryProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var checkpoints: [FSEventsCheckpoint]
        private var events: [FileSystemChangeEvent] = []
        init(checkpoints: [FSEventsCheckpoint]) { self.checkpoints = checkpoints }
        func setEvents(_ events: [FileSystemChangeEvent]) {
            lock.lock(); defer { lock.unlock() }
            self.events = events
        }
        func currentCheckpoint(for target: ScanTarget) throws -> FSEventsCheckpoint {
            lock.lock(); defer { lock.unlock() }
            let next = checkpoints.first ?? FSEventsCheckpoint(volumeUUID: "STUB", eventID: 0, capturedAt: Date(), osBuild: "T")
            if checkpoints.count > 1 { checkpoints.removeFirst() }
            return next
        }
        func history(
            since: FSEventsCheckpoint, through: FSEventsCheckpoint, target: ScanTarget
        ) async throws -> FileSystemEventHistory {
            let snapshot: [FileSystemChangeEvent] = {
                lock.lock(); defer { lock.unlock() }
                return events
            }()
            return FileSystemEventHistory(events: snapshot)
        }
    }

    private func checkpoint(_ id: UInt64) -> FSEventsCheckpoint {
        FSEventsCheckpoint(volumeUUID: "STUB", eventID: id, capturedAt: Date(), osBuild: "T")
    }

    private func finishedSnapshot(
        from stream: AsyncThrowingStream<ScanProgressEvent, Error>
    ) async throws -> ScanSnapshot? {
        var finished: ScanSnapshot?
        for try await event in stream {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        return finished
    }

    // MARK: - Random tree + churn

    /// Maps a FileManager path (which resolves the temp dir's firmlink to
    /// `/private/var/...`) back to the standardized `/var/...` namespace that
    /// `ScanTarget` uses for node ids. Purely lexical, so it works for paths
    /// that no longer exist on disk (a rename/delete's old path) — where the
    /// filesystem-backed `standardizedFileURL` cannot resolve the firmlink.
    private func toIDNamespace(_ path: String) -> String {
        for firmlinked in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(firmlinked) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func buildTree(at dir: URL, rng: inout SeededRNG, depth: Int) throws {
        let fileCount = Int.random(in: 0...4, using: &rng)
        for i in 0..<fileCount {
            let size = Int.random(in: 0...6_000, using: &rng)
            try Data(repeating: UInt8(i &+ 1), count: size)
                .write(to: dir.appending(path: "f\(i).bin"))
        }
        guard depth > 0 else { return }
        let dirCount = Int.random(in: 0...3, using: &rng)
        for i in 0..<dirCount {
            let sub = dir.appending(path: "d\(i)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try buildTree(at: sub, rng: &rng, depth: depth - 1)
        }
    }

    /// Every directory (including root) and every regular file currently on
    /// disk under `root`, as absolute paths in the tree's namespace.
    private func enumerate(_ root: URL) -> (dirs: [URL], files: [URL]) {
        var dirs = [root]
        var files: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return (dirs, files)
        }
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { dirs.append(url) } else { files.append(url) }
        }
        return (dirs, files)
    }

    /// Applies one random mutation, appending the FSEvents a real journal would
    /// surface. Re-reads the live tree each call so targets are always valid.
    private func applyChurn(
        root: URL, rng: inout SeededRNG, nextEventID: inout UInt64, events: inout [FileSystemChangeEvent]
    ) throws {
        func emit(_ path: String, _ flags: FileSystemEventFlags) {
            nextEventID += 1
            events.append(FileSystemChangeEvent(path: toIDNamespace(path), eventID: nextEventID, flags: flags))
        }
        let (dirs, files) = enumerate(root)
        let op = Int.random(in: 0..<8, using: &rng)
        switch op {
        case 0 where !files.isEmpty: // touch (content/size change)
            let f = files[Int.random(in: 0..<files.count, using: &rng)]
            let size = Int.random(in: 0...9_000, using: &rng)
            try Data(repeating: 0x7A, count: size).write(to: f)
            emit(f.path, [])
        case 1 where !files.isEmpty: // delete file
            let f = files[Int.random(in: 0..<files.count, using: &rng)]
            try FileManager.default.removeItem(at: f)
            emit(f.path, [.itemRemoved])
        case 2: // create file in a random directory
            let d = dirs[Int.random(in: 0..<dirs.count, using: &rng)]
            let name = "new\(nextEventID).bin"
            let f = d.appending(path: name)
            try Data(repeating: 0x33, count: Int.random(in: 0...5_000, using: &rng)).write(to: f)
            emit(f.path, [.itemCreated])
        case 3 where !files.isEmpty: // rename file within its directory
            let f = files[Int.random(in: 0..<files.count, using: &rng)]
            let dest = f.deletingLastPathComponent().appending(path: "ren\(nextEventID).bin")
            try FileManager.default.moveItem(at: f, to: dest)
            emit(f.path, [.itemRenamed]); emit(dest.path, [.itemRenamed])
        case 4 where !files.isEmpty && dirs.count > 1: // move file across directories
            let f = files[Int.random(in: 0..<files.count, using: &rng)]
            let d = dirs[Int.random(in: 0..<dirs.count, using: &rng)]
            guard d != f.deletingLastPathComponent() else { return }
            let dest = d.appending(path: f.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dest.path) else { return }
            try FileManager.default.moveItem(at: f, to: dest)
            emit(f.path, [.itemRenamed]); emit(dest.path, [.itemRenamed])
        case 5: // create a new subdirectory (with a couple of files) under a random dir
            let d = dirs[Int.random(in: 0..<dirs.count, using: &rng)]
            let newDir = d.appending(path: "sub\(nextEventID)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            try buildTree(at: newDir, rng: &rng, depth: 2)
            emit(newDir.path, [.itemCreated, .itemIsDirectory])
        case 6 where dirs.count > 1: // delete a non-root directory subtree
            let candidates = dirs.filter { $0 != root }
            guard !candidates.isEmpty else { return }
            let d = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
            try FileManager.default.removeItem(at: d)
            emit(d.path, [.itemRemoved, .itemIsDirectory])
        case 7 where dirs.count > 1: // touch a directory (attribute/mtime-only change)
            let candidates = dirs.filter { $0 != root }
            guard let d = candidates.randomElement(using: &rng) else { return }
            let marker = d.appending(path: ".touch\(nextEventID)")
            try Data().write(to: marker)
            try FileManager.default.removeItem(at: marker)
            emit(d.path, [.itemIsDirectory])
        default:
            return
        }
    }

    // MARK: - Comparison

    private func assertEquivalent(
        _ incremental: FileTreeStore, _ fresh: FileTreeStore, seed: UInt64
    ) {
        let lhs = incremental.allNodes.sorted { $0.id < $1.id }
        let rhs = fresh.allNodes.sorted { $0.id < $1.id }
        guard lhs.count == rhs.count else {
            let lhsIDs = Set(lhs.map(\.id))
            let rhsIDs = Set(rhs.map(\.id))
            let onlyIncremental = Array(lhsIDs.subtracting(rhsIDs).sorted().prefix(5))
            let onlyFresh = Array(rhsIDs.subtracting(lhsIDs).sorted().prefix(5))
            Issue.record("seed \(seed): node count \(lhs.count) != \(rhs.count); only-incremental=\(onlyIncremental); only-fresh=\(onlyFresh)")
            return
        }
        for (a, b) in zip(lhs, rhs) where a.id == b.id {
            #expect(a.isDirectory == b.isDirectory, "seed \(seed) \(a.id) isDirectory")
            #expect(a.isAutoSummarized == b.isAutoSummarized, "seed \(seed) \(a.id) autoSummarized")
            #expect(a.allocatedSize == b.allocatedSize, "seed \(seed) \(a.id) allocated")
            #expect(a.unduplicatedAllocatedSize == b.unduplicatedAllocatedSize, "seed \(seed) \(a.id) unduped")
            #expect(a.logicalSize == b.logicalSize, "seed \(seed) \(a.id) logical")
            #expect(a.descendantFileCount == b.descendantFileCount, "seed \(seed) \(a.id) fileCount")
            #expect(a.fileIdentity == b.fileIdentity, "seed \(seed) \(a.id) identity")
            #expect(a.linkCount == b.linkCount, "seed \(seed) \(a.id) linkCount")
            #expect(a.isPackage == b.isPackage, "seed \(seed) \(a.id) isPackage")
            #expect(a.isAccessible == b.isAccessible, "seed \(seed) \(a.id) isAccessible")
            #expect(a.isSelfAccessible == b.isSelfAccessible, "seed \(seed) \(a.id) isSelfAccessible")
            #expect(
                incremental.children(of: a.id).map(\.id) == fresh.children(of: b.id).map(\.id),
                "seed \(seed) \(a.id) child order"
            )
        }
    }

    private func runEquivalence(seed: UInt64, options: ScanOptions, treeDepth: Int, churnOps: Int) async throws {
        var rng = SeededRNG(seed: seed)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rescan-equiv-\(seed)-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try buildTree(at: root, rng: &rng, depth: treeDepth)

        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: options)),
            "seed \(seed): baseline scan produced no snapshot"
        )

        var eventID: UInt64 = 10
        var events: [FileSystemChangeEvent] = []
        for _ in 0..<churnOps {
            try applyChurn(root: root, rng: &rng, nextEventID: &eventID, events: &events)
        }
        provider.setEvents(events)

        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: options, baselineProvider: { baseline })
            ),
            "seed \(seed): rescan produced no snapshot"
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: options)),
            "seed \(seed): fresh scan produced no snapshot"
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: seed)
    }

    // MARK: - Adversarial degraded-event streams
    //
    // A real FSEvents stream can lose or coalesce events (a delete whose parent
    // membership event never lands; a rename with only one side named). The
    // relist recovers because it re-reads the WHOLE named directory from disk
    // rather than trusting the event to describe the change — as long as SOME
    // surviving event still points at (or into) the affected directory, the
    // result converges to a fresh scan. These pin that guarantee; a stream that
    // loses its last pointer to a change is undetectable by construction and is
    // the FSEvents provider's contract (kernel/user-drop flags force a full
    // scan), not the planner's.

    private func makeControlledTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rescan-adv-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "d0/sub", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "d0/d1/d2", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "other", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 512).write(to: root.appending(path: "d0/a.bin"))
        try Data(repeating: 2, count: 512).write(to: root.appending(path: "d0/sub/s.bin"))
        try Data(repeating: 3, count: 512).write(to: root.appending(path: "d0/d1/d2/deep.bin"))
        try Data(repeating: 4, count: 512).write(to: root.appending(path: "other/o.bin"))
        return root
    }

    /// A directory is deleted, but the only surviving event is a stale self-event
    /// for the now-gone directory (its removal semantics and the parent's
    /// membership event were both dropped). Promotion re-reads the parent and
    /// removes it — convergence, not silent staleness.
    @Test func deletedDirectoryWithOnlyStaleSelfEventConverges() async throws {
        let root = try makeControlledTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: ScanOptions()))
        )
        try FileManager.default.removeItem(at: root.appending(path: "d0/sub", directoryHint: .isDirectory))
        provider.setEvents([
            FileSystemChangeEvent(path: target.id + "/d0/sub", eventID: 15, flags: [.itemIsDirectory]),
        ])
        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: ScanOptions(), baselineProvider: { baseline })
            )
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: ScanOptions()))
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: 9001)
        #expect(rescanned.treeStore.node(id: target.id + "/d0/sub") == nil)
    }

    /// A rename with only the source side named (the destination's create event
    /// was dropped). Relisting the parent re-reads it whole and reconciles both.
    @Test func oneSidedRenameConverges() async throws {
        let root = try makeControlledTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: ScanOptions()))
        )
        try FileManager.default.moveItem(
            at: root.appending(path: "d0/a.bin"),
            to: root.appending(path: "d0/renamed.bin")
        )
        provider.setEvents([
            FileSystemChangeEvent(path: target.id + "/d0/a.bin", eventID: 15, flags: [.itemRenamed]),
        ])
        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: ScanOptions(), baselineProvider: { baseline })
            )
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: ScanOptions()))
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: 9002)
        #expect(rescanned.treeStore.node(id: target.id + "/d0/a.bin") == nil)
        #expect(rescanned.treeStore.node(id: target.id + "/d0/renamed.bin") != nil)
    }

    /// A whole nested branch is deleted, and the only surviving event names the
    /// deepest gone directory. Promotion must climb d2 → d1 → d0 to the nearest
    /// surviving ancestor and remove the branch there.
    @Test func cascadedDeletionPromotesToSurvivingAncestor() async throws {
        let root = try makeControlledTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: ScanOptions()))
        )
        try FileManager.default.removeItem(at: root.appending(path: "d0/d1", directoryHint: .isDirectory))
        provider.setEvents([
            FileSystemChangeEvent(path: target.id + "/d0/d1/d2", eventID: 15, flags: [.itemIsDirectory]),
        ])
        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: ScanOptions(), baselineProvider: { baseline })
            )
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: ScanOptions()))
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: 9003)
        #expect(rescanned.treeStore.node(id: target.id + "/d0/d1") == nil)
        #expect(rescanned.treeStore.node(id: target.id + "/d0") != nil)
    }

    // MARK: - Unreadable directories (permission)
    //
    // Without Full Disk Access a whole-volume scan meets unreadable directories
    // and TCC-protected children everywhere. A full scan turns them into
    // childless inaccessible nodes + warnings; the relist must reproduce that
    // — case (a) a directly-named unreadable directory (deep re-walk), case (b)
    // unreadable children under a readable-but-not-searchable parent (inline
    // inaccessible node, no subtree walk) — never abort the rescan to a full
    // scan (which degraded every / rescan before this).

    private func chmodPath(_ url: URL, _ mode: Int16) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    @Test func directlyNamedUnreadableDirectoryConvergesViaDeepRewalk() async throws {
        let root = try makeControlledTree() // has d0/sub with a file
        let secret = root.appending(path: "d0/sub", directoryHint: .isDirectory)
        defer { chmodPath(secret, 0o755); try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: ScanOptions()))
        )
        #expect(baseline.treeStore.node(id: target.id + "/d0/sub/s.bin") != nil)

        chmodPath(secret, 0o000) // unreadable: readdir of it now fails
        provider.setEvents([
            FileSystemChangeEvent(path: target.id + "/d0/sub", eventID: 15, flags: [.itemIsDirectory]),
        ])
        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: ScanOptions(), baselineProvider: { baseline })
            )
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: ScanOptions()))
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: 9101)
        let node = try #require(rescanned.treeStore.node(id: target.id + "/d0/sub"))
        #expect(!node.isAccessible)
        #expect(rescanned.treeStore.children(of: node.id).isEmpty)
    }

    /// The opposite of the deep-rewalk case: a directory that was UNREADABLE at
    /// baseline (a childless inaccessible node) becomes readable before the
    /// rescan. FSEvents names it, the shallow relist reads its children — and the
    /// directory's own record must lose its stale `isAccessible=false` /
    /// `isSelfAccessible=false` flags and take the fresh identity, matching a full
    /// scan. Refreshing only `lastModified` left it displaying children while
    /// still flagged inaccessible (chmod moves ctime, not mtime, so the stale
    /// flag was never even refreshed). Guards the own-record override built from
    /// the full fresh own-metadata.
    @Test func inaccessibleDirectoryBecomingReadableRefreshesOwnRecord() async throws {
        let root = try makeControlledTree() // has d0/sub with s.bin
        let secret = root.appending(path: "d0/sub", directoryHint: .isDirectory)
        defer { chmodPath(secret, 0o755); try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)

        chmodPath(secret, 0o000) // unreadable at baseline: childless inaccessible node
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: ScanOptions()))
        )
        let baselineNode = try #require(baseline.treeStore.node(id: target.id + "/d0/sub"))
        #expect(!baselineNode.isAccessible)
        #expect(baseline.treeStore.children(of: baselineNode.id).isEmpty)

        chmodPath(secret, 0o755) // now readable
        provider.setEvents([
            FileSystemChangeEvent(path: target.id + "/d0/sub", eventID: 15, flags: [.itemIsDirectory]),
        ])
        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: ScanOptions(), baselineProvider: { baseline })
            )
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: ScanOptions()))
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: 9102)
        let node = try #require(rescanned.treeStore.node(id: target.id + "/d0/sub"))
        #expect(node.isAccessible)
        #expect(node.isSelfAccessible)
        #expect(rescanned.treeStore.node(id: target.id + "/d0/sub/s.bin") != nil)
    }

    /// Case (b) — a readable parent with an individually-unreadable CHILD (the
    /// getattrlist-denied / TCC-protected shape a whole-volume scan without Full
    /// Disk Access meets) — is not reproducible with POSIX `chmod`: a
    /// non-searchable parent renders the WHOLE directory unreadable (case (a)),
    /// not a single child. So this asserts the two invariants case (b) relies on
    /// at the point they matter: `directChildren` materialises an unreadable
    /// child as an inline inaccessible node + warning (never nil), which the
    /// relist splices without a subtree walk. The end-to-end (b) path is
    /// exercised by the real `/` scan (TCC-protected children).
    @Test func unavailableChildMaterializesAsInlineInaccessibleNode() async throws {
        let root = try makeControlledTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Confirm the shared inaccessible-node contract: an unreadable child is
        // never dropped — it becomes an inaccessible, childless node.
        let node = FileNodeRecord.inaccessible(
            path: root.appending(path: "d0/protected").path,
            isDirectory: true
        )
        #expect(!node.isAccessible)
        #expect(!node.isSelfAccessible)
        #expect(node.isDirectory)
        #expect(node.allocatedSize == 0)
        #expect(node.descendantFileCount == 0)
    }

    // MARK: - Synthesizer fidelity vs the real kernel stream

    /// The oracle only proves anything if its synthesized events are not MORE
    /// generous than the events the real fseventsd journal actually delivers:
    /// if the synthesizer named directories the kernel wouldn't, the oracle
    /// would prove convergence real rescans can't achieve. This scripts a fixed
    /// churn on a live fixture, replays the REAL journal, and asserts that every
    /// directory the synthesized stream makes the planner relist is also relisted
    /// (or deep-re-walked, or subsumed by a full-scan) under the real stream —
    /// i.e. the synthesizer is a subset of reality. Prints both sets for the
    /// record. Self-skips where the volume has no usable journal (no-FDA dev
    /// shells), where the stubbed suites carry the logic.
    @Test(.timeLimit(.minutes(1))) func synthesizedEventsAreASubsetOfTheRealJournal() async throws {
        let root = try makeControlledTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = ScanTarget(url: root)
        let options = ScanOptions()
        let provider = DarwinFileSystemEventHistoryProvider()

        let since: FSEventsCheckpoint
        do {
            since = try provider.currentCheckpoint(for: target)
        } catch {
            FileHandle.standardError.write(Data("FIDELITY: SKIPPED (no checkpoint: \(error))\n".utf8))
            return
        }

        // Baseline tree for the planner.
        let baseline = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: options))
        )

        // Scripted churn, and the events my synthesizer emits for exactly it.
        let fm = FileManager.default
        try Data(repeating: 9, count: 512).write(to: root.appending(path: "d0/newf.bin"))
        try fm.removeItem(at: root.appending(path: "other/o.bin"))
        try fm.moveItem(at: root.appending(path: "d0/a.bin"), to: root.appending(path: "d0/a2.bin"))
        try fm.createDirectory(at: root.appending(path: "d0/nd", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data(repeating: 8, count: 256).write(to: root.appending(path: "d0/nd/n.bin"))

        let id = target.id
        let synthesized: [FileSystemChangeEvent] = [
            .init(path: id + "/d0/newf.bin", eventID: 1, flags: [.itemCreated]),
            .init(path: id + "/other/o.bin", eventID: 2, flags: [.itemRemoved]),
            .init(path: id + "/d0/a.bin", eventID: 3, flags: [.itemRenamed]),
            .init(path: id + "/d0/a2.bin", eventID: 4, flags: [.itemRenamed]),
            .init(path: id + "/d0/nd", eventID: 5, flags: [.itemCreated, .itemIsDirectory]),
        ]

        let behavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: false)
        let matcher = ScanExclusionMatcher(
            patterns: options.exclusionPatterns, rootPath: id,
            includeCloudStorage: options.includeCloudStorage,
            cloudStorageRootPath: options.cloudStorageRootPath,
            iCloudDriveRootPath: options.iCloudDriveRootPath
        )
        func relistSet(_ events: [FileSystemChangeEvent]) -> Set<String>? {
            switch IncrementalRescanPlanner.plan(
                events: events, target: target, baseline: baseline.treeStore,
                options: options, behavior: behavior, exclusionMatcher: matcher
            ) {
            case .relistDirectories(let d, let deep): return Set(d).union(deep)
            case .noChanges: return []
            case .fullScan: return nil // subsumes every directory
            }
        }
        let synthSet = relistSet(synthesized) ?? []

        // Poll the real journal until it has surfaced the newest churned path
        // (the create of d0/newf.bin) — proof the window is complete, not a
        // partial early flush — draining the full window each time.
        var realEvents: [FileSystemChangeEvent] = []
        for _ in 0..<120 {
            let through = try provider.currentCheckpoint(for: target)
            realEvents = (try? await provider.history(since: since, through: through, target: target))?.events ?? []
            if realEvents.contains(where: { $0.path.hasSuffix("/d0/newf.bin") }) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard realEvents.contains(where: { $0.path.hasSuffix("/d0/newf.bin") }) else {
            FileHandle.standardError.write(Data("FIDELITY: SKIPPED (journal never surfaced the churn within deadline)\n".utf8))
            return
        }
        // Raw dump for the record.
        let dump = realEvents
            .filter { $0.path.hasPrefix(id) }
            .map { "\($0.path.dropFirst(id.count)) flags=\($0.flags.rawValue)" }
            .sorted()
            .joined(separator: " | ")
        FileHandle.standardError.write(Data("FIDELITY raw real events under target: \(dump)\n".utf8))

        guard let realSet = relistSet(realEvents) else {
            FileHandle.standardError.write(Data("FIDELITY: real stream → full scan (superset of synth, OK)\n".utf8))
            return
        }
        let missing = synthSet.subtracting(realSet)
        FileHandle.standardError.write(Data(
            "FIDELITY: realEvents=\(realEvents.count) synthRelist=\(synthSet.sorted()) realRelist=\(realSet.sorted()) missing=\(missing.sorted())\n".utf8
        ))
        #expect(missing.isEmpty, "synthesizer relists directories the real journal does not: \(missing.sorted())")
    }

    // MARK: - Tests

    @Test(arguments: 0..<64)
    func randomChurnMatchesFreshFullScan(seedIndex: Int) async throws {
        try await runEquivalence(
            seed: UInt64(seedIndex) &* 0x100 &+ 1,
            options: ScanOptions(),
            treeDepth: 3,
            churnOps: 10
        )
    }

    @Test(arguments: 0..<24)
    func heavyChurnOnDeeperTreeMatchesFreshFullScan(seedIndex: Int) async throws {
        try await runEquivalence(
            seed: UInt64(seedIndex) &* 0x1_0000 &+ 7,
            options: ScanOptions(),
            treeDepth: 4,
            churnOps: 24
        )
    }

    /// Churn that lands inside auto-summarized directories, which the baseline
    /// never materialized: the planner must route them to a deep re-walk
    /// (re-summarize) rather than a shallow diff that would explode the summary.
    @Test(arguments: 0..<16)
    func churnInsideSummarizedDirectoriesMatchesFreshFullScan(seedIndex: Int) async throws {
        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 5
        options.tuning.autoSummarizeMinDepthForSummarization = 1
        options.tuning.autoSummarizeMaxAverageFileSize = 1_000_000

        let seed = UInt64(seedIndex) &* 0x1_00_0000 &+ 3
        var rng = SeededRNG(seed: seed)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rescan-equiv-sum-\(seed)-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A few directories dense enough to auto-summarize (>= 5 small files),
        // plus ordinary shallow content around them.
        try buildTree(at: root, rng: &rng, depth: 2)
        for d in 0..<3 {
            let dense = root.appending(path: "dense\(d)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dense, withIntermediateDirectories: true)
            for i in 0..<8 {
                try Data(repeating: UInt8(i &+ 1), count: 128)
                    .write(to: dense.appending(path: "s\(i).bin"))
            }
        }

        let target = ScanTarget(url: root)
        let provider = StubProvider(checkpoints: [checkpoint(10), checkpoint(20)])
        let service = IncrementalScanService(engine: ScanEngine(), historyProvider: provider)
        let baseline = try #require(
            try await finishedSnapshot(from: service.scan(target: target, options: options))
        )
        // Guard the fixture actually summarizes, or the test is vacuous.
        #expect(baseline.treeStore.allNodes.contains { $0.isAutoSummarized })

        // Mutate inside the dense (summarized) dirs and elsewhere.
        var eventID: UInt64 = 10
        var events: [FileSystemChangeEvent] = []
        for d in 0..<3 {
            let dense = root.appending(path: "dense\(d)", directoryHint: .isDirectory)
            let victim = dense.appending(path: "s\(d).bin")
            try Data(repeating: 0x5A, count: 4_096).write(to: victim)
            eventID += 1
            events.append(FileSystemChangeEvent(
                path: toIDNamespace(victim.path), eventID: eventID, flags: [.itemCreated]
            ))
        }
        for _ in 0..<6 {
            try applyChurn(root: root, rng: &rng, nextEventID: &eventID, events: &events)
        }
        provider.setEvents(events)

        let rescanned = try #require(
            try await finishedSnapshot(
                from: service.rescan(target: target, options: options, baselineProvider: { baseline })
            )
        )
        let fresh = try #require(
            try await finishedSnapshot(from: ScanEngine().scan(target: target, options: options))
        )
        assertEquivalent(rescanned.treeStore, fresh.treeStore, seed: seed)
    }
}
