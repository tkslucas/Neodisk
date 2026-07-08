//
//  DuplicatesModel.swift
//  Neodisk
//
//  Duplicate-finder state for the statistics panel's Duplicates tab: an
//  on-demand content scan of the displayed snapshot (hashing costs real
//  I/O, so it never runs unasked), its results, and the drill-in into one
//  duplicate group. Owned by NeodiskViewModel as `model.duplicates`.
//
//  Read-only, like the app promises: the finder only reads file contents;
//  cleaning up happens in Finder.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class DuplicatesModel {
    enum Phase {
        case idle
        case scanning
        case finished(DuplicateScanResults)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Hashing progress, 0...1, while `phase == .scanning`.
    private(set) var progress = 0.0
    /// The group the user drilled into, if any.
    private(set) var openGroup: DuplicateGroup?

    /// Every confirmed duplicate, for the map-wide highlight while the
    /// results list is showing. Cached because the union set is derived
    /// per render otherwise.
    @ObservationIgnored private var allDuplicateIDs: Set<String> = []
    /// Which group each duplicate belongs to, so clicking a copy on the
    /// treemap can open its group.
    @ObservationIgnored private var groupIndexByNodeID: [String: Int] = [:]
    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// The snapshot the current phase belongs to; a scan finishing after
    /// the displayed tree changed must not publish stale results.
    @ObservationIgnored private var scannedSnapshotID: UUID?

    init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var results: DuplicateScanResults? {
        if case .finished(let results) = phase { return results }
        return nil
    }

    /// Scanning hashes file contents against the displayed tree, so it needs
    /// a complete snapshot and no scan already running.
    var canScan: Bool {
        coordinator.snapshot?.isComplete == true && !isScanning
    }

    /// Nodes lit on the treemap: the open group's copies, or every
    /// duplicate while the results list is showing.
    var highlightedNodeIDs: Set<String>? {
        if let openGroup { return Set(openGroup.nodeIDs) }
        guard case .finished = phase, !allDuplicateIDs.isEmpty else { return nil }
        return allDuplicateIDs
    }

    func startScan() {
        guard canScan, let snapshot = coordinator.snapshot else { return }
        let store = snapshot.treeStore
        let snapshotID = snapshot.id
        scannedSnapshotID = snapshotID
        phase = .scanning
        progress = 0
        openGroup = nil
        allDuplicateIDs = []
        groupIndexByNodeID = [:]
        scanTask?.cancel()
        // Built in method scope, not inside the detached work, so the
        // sendable hashing closure never touches the model directly.
        let reportProgress: @Sendable (DuplicateScanProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.scannedSnapshotID == snapshotID else { return }
                self.progress = max(self.progress, update.fractionCompleted)
            }
        }
        scanTask = Task { [weak self] in
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try await DuplicateFinder.findDuplicates(in: store, onProgress: reportProgress)
                }.value
                guard let self, !Task.isCancelled,
                      self.scannedSnapshotID == snapshotID else { return }
                self.allDuplicateIDs = Set(results.groups.flatMap(\.nodeIDs))
                var indexByNodeID: [String: Int] = [:]
                for (index, group) in results.groups.enumerated() {
                    for nodeID in group.nodeIDs {
                        indexByNodeID[nodeID] = index
                    }
                }
                self.groupIndexByNodeID = indexByNodeID
                self.phase = .finished(results)
            } catch is CancellationError {
                // cancelScan / snapshotDidChange already reset the phase.
            } catch {
                guard let self, self.scannedSnapshotID == snapshotID else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        progress = 0
    }

    func open(_ group: DuplicateGroup) {
        openGroup = group
    }

    /// Routes a selection (treemap or outline click) into the drill-in:
    /// selecting a duplicate opens its group — same as clicking the group
    /// row; selecting anything else while a group is open steps back out to
    /// the all-duplicates view, so clicking a dimmed cell is the intuitive
    /// "back". With no group open, non-duplicate selections change nothing.
    func handleSelection(of nodeID: String) {
        guard case .finished(let results) = phase else { return }
        if let index = groupIndexByNodeID[nodeID] {
            openGroup = results.groups[index]
        } else if openGroup != nil {
            openGroup = nil
        }
    }

    func closeGroup() {
        openGroup = nil
    }

    /// The displayed tree changed: results and the drill-in hold node IDs of
    /// the replaced tree, and a scan in flight is hashing files that may no
    /// longer exist.
    func snapshotDidChange() {
        scanTask?.cancel()
        scanTask = nil
        scannedSnapshotID = nil
        phase = .idle
        progress = 0
        openGroup = nil
        allDuplicateIDs = []
        groupIndexByNodeID = [:]
    }
}
