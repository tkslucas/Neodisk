//
//  TokenModel.swift
//  Neodisk
//
//  Token mode: counts the scan's text files once it finishes and builds a
//  token-weighted copy of the tree for the treemap.
//

import Foundation
import Observation
import NeodiskKit

/// What the treemap's areas measure.
enum SizeMetric: String, CaseIterable, Sendable {
    case bytes
    case tokens
}

@MainActor
@Observable
final class TokenModel {
    enum Phase: Equatable {
        case idle
        case waitingForScan
        case counting(done: Int, total: Int)
        case ready
    }

    private(set) var phase: Phase = .idle
    private(set) var tally: TokenTally?
    /// The scan with every size replaced by its token count.
    private(set) var tokenSnapshot: ScanSnapshot?
    /// Text files, most tokens first.
    private(set) var rankedFileIDs: [String] = []
    /// Agent instruction files (CLAUDE.md, AGENTS.md, …), most tokens first.
    private(set) var agentFileIDs: [String] = []
    /// Dims everything but the agent files on the map.
    var highlightsAgentFiles = false

    var isActive = false {
        didSet { if isActive != oldValue { refresh() } }
    }

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let cache = TokenCountCache()
    @ObservationIgnored private var run: CountRun?
    @ObservationIgnored private var countedSnapshotID: UUID?

    init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
    }

    var tokenStore: FileTreeStore? { tokenSnapshot?.treeStore }

    /// Tokens for a file or folder; nil for files that weren't counted.
    func tokens(for nodeID: String) -> Int? {
        if let tokens = tally?.tokensByID[nodeID] { return tokens }
        guard let node = tokenStore?.node(id: nodeID), node.isDirectory else { return nil }
        return Int(node.allocatedSize)
    }

    func isSampled(_ nodeID: String) -> Bool {
        tally?.sampledIDs.contains(nodeID) ?? false
    }

    /// The files with the most tokens inside `folderID` (the whole scan when nil).
    func topFileIDs(in folderID: String?, limit: Int) -> [String] {
        guard let folderID, let root = tokenStore?.root, folderID != root.id else {
            return Array(rankedFileIDs.prefix(limit))
        }
        let prefix = folderID.hasSuffix("/") ? folderID : folderID + "/"
        var result: [String] = []
        for id in rankedFileIDs where id.hasPrefix(prefix) {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }

    /// Starts, resumes, or drops counting to match the active state and the
    /// displayed snapshot. Counts only once a scan is no longer running.
    func refresh() {
        guard let snapshot = coordinator.snapshot else {
            reset()
            return
        }
        if snapshot.id != countedSnapshotID, run?.snapshotID != snapshot.id {
            run?.cancel()
            run = nil
            countedSnapshotID = nil
            // A rescan of the same location keeps the old map until the recount lands.
            if tokenSnapshot?.target.id != snapshot.target.id {
                tokenSnapshot = nil
                tally = nil
                rankedFileIDs = []
                agentFileIDs = []
            }
        }
        guard isActive else {
            run?.cancel()
            run = nil
            phase = countedSnapshotID == nil ? .idle : .ready
            return
        }
        if countedSnapshotID == snapshot.id {
            phase = .ready
        } else if coordinator.isScanning {
            phase = .waitingForScan
        } else if run == nil {
            start(snapshot)
        }
    }

    private func reset() {
        run?.cancel()
        run = nil
        tokenSnapshot = nil
        tally = nil
        rankedFileIDs = []
        agentFileIDs = []
        countedSnapshotID = nil
        highlightsAgentFiles = false
        phase = .idle
    }

    private func start(_ snapshot: ScanSnapshot) {
        let run = CountRun(snapshotID: snapshot.id)
        self.run = run
        phase = .counting(done: 0, total: 0)
        let cache = cache
        let progress = run.progress

        run.task = Task { [weak self] in
            let pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, self.run === run else { return }
                    let (done, total) = progress.current
                    self.phase = .counting(done: done, total: total)
                }
            }
            defer { pollTask.cancel() }

            let result = await Task.detached(priority: .utility) {
                Self.count(snapshot, cache: cache, progress: progress)
            }.value
            guard let self, self.run === run, let result else { return }
            self.tally = result.tally
            self.tokenSnapshot = result.snapshot
            self.rankedFileIDs = result.rankedFileIDs
            self.agentFileIDs = result.agentFileIDs
            self.countedSnapshotID = snapshot.id
            self.run = nil
            self.phase = .ready
        }
    }

    private struct CountResult: Sendable {
        let tally: TokenTally
        let snapshot: ScanSnapshot
        let rankedFileIDs: [String]
        let agentFileIDs: [String]
    }

    nonisolated private static func count(
        _ snapshot: ScanSnapshot,
        cache: TokenCountCache,
        progress: CountProgress
    ) -> CountResult? {
        let store = snapshot.treeStore
        guard let tally = TokenCountService.count(
            store: store,
            cache: cache,
            progress: { progress.update(done: $0, total: $1) },
            isCancelled: { progress.isCancelled }
        ) else { return nil }

        let tokenStore = store.reweighted { Int64(tally.tokensByID[$0.id] ?? 0) }
        let ranked = tally.tokensByID.sorted { $0.value > $1.value }.map(\.key)
        let agentFiles = ranked.filter { id in
            store.node(id: id).map(AgentInstructionFiles.matches) ?? false
        }
        let tokenSnapshot = ScanSnapshot(
            target: snapshot.target,
            treeStore: tokenStore,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            scanWarnings: [],
            aggregateStats: tokenStore.aggregateStats,
            isComplete: true,
            source: snapshot.source
        )
        return CountResult(tally: tally, snapshot: tokenSnapshot, rankedFileIDs: ranked, agentFileIDs: agentFiles)
    }
}

@MainActor
private final class CountRun {
    let snapshotID: UUID
    let progress = CountProgress()
    var task: Task<Void, Never>?

    init(snapshotID: UUID) {
        self.snapshotID = snapshotID
    }

    func cancel() {
        progress.cancel()
        task?.cancel()
    }
}

/// Progress and cancellation shared with the counting workers.
private final class CountProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var total = 0
    private var cancelled = false

    var current: (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (done, total)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func update(done: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.done = max(self.done, done)
        self.total = total
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
