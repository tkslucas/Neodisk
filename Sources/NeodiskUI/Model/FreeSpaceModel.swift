// Synthetic space beside the tree (free and hidden): the sunburst always draws it for volume scans, the
// treemap only behind the Settings toggle.

import AppKit
import Combine
import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class FreeSpaceModel {
    /// The treemap reads it through `treemapFreeSpaceBytes`, behind the Settings toggle.
    private(set) var freeSpaceBytes: Int64?
    /// Capacity neither free nor scanned (purgeable, local snapshots, unreadable files). Needs a complete
    /// snapshot: mid-scan the remainder is unknown, not hidden.
    private(set) var hiddenSpaceBytes: Int64?
    /// Capacity minus available, as Finder reports it; equals scanned + hidden once a scan finishes.
    private(set) var finderUsedBytes: Int64?
    /// Detail beside free space, never its own segment, as Finder folds purgeable into available.
    private(set) var purgeableBytes: Int64?

    /// Toggle reactivity rides on bindPreferences' sink calling update(), which reassigns the bytes.
    @ObservationIgnored var preferences: AppPreferences?

    @ObservationIgnored private let coordinator: ScanCoordinator

    @ObservationIgnored private let loadVolume: @Sendable (URL) async -> VolumeSpaceInfo?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeKey: VolumeKey?
    @ObservationIgnored private var volumeInfo: VolumeSpaceInfo?
    @ObservationIgnored private var mountObserver: AnyCancellable?

    private struct VolumeKey: Equatable {
        let targetID: String
        let completedSnapshotID: UUID?
    }

    init(
        coordinator: ScanCoordinator,
        loadVolume: @escaping @Sendable (URL) async -> VolumeSpaceInfo? = { VolumeSpaceInfo.load(for: $0) }
    ) {
        self.coordinator = coordinator
        self.loadVolume = loadVolume
        let notifications = NSWorkspace.shared.notificationCenter
        mountObserver = notifications.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: notifications.publisher(for: NSWorkspace.didUnmountNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateVolume() }
            }
    }

    deinit { volumeTask?.cancel() }

    func invalidateVolume() {
        volumeTask?.cancel()
        volumeTask = nil
        volumeKey = nil
        volumeInfo = nil
        update()
    }

    var treemapFreeSpaceBytes: Int64? {
        preferences?.showFreeSpace == true ? freeSpaceBytes : nil
    }
    var treemapHiddenSpaceBytes: Int64? {
        preferences?.showFreeSpace == true ? hiddenSpaceBytes : nil
    }

    func update() {
        guard let target = coordinator.selectedTarget, target.kind == .volume else {
            volumeTask?.cancel()
            volumeTask = nil
            volumeKey = nil
            volumeInfo = nil
            applyVolumeInfo(nil)
            return
        }
        // One cached result for the displayed volume. Partial trees and preference
        // changes reuse it; completing a scan or remounting requests fresh values.
        let key = VolumeKey(
            targetID: target.id,
            completedSnapshotID: coordinator.snapshot.flatMap { $0.isComplete ? $0.id : nil }
        )
        if key != volumeKey {
            volumeTask?.cancel()
            if key.targetID != volumeKey?.targetID { volumeInfo = nil }
            volumeKey = key
            volumeTask = Task { [weak self, loadVolume] in
                let info = await loadVolume(target.url)
                guard !Task.isCancelled, let self,
                      self.volumeKey == key,
                      self.coordinator.selectedTarget?.id == key.targetID else { return }
                self.volumeInfo = info
                self.volumeTask = nil
                self.applyVolumeInfo(info)
            }
        }
        applyVolumeInfo(volumeInfo)
    }

    private func applyVolumeInfo(_ info: VolumeSpaceInfo?) {
        guard let info else {
            freeSpaceBytes = nil
            hiddenSpaceBytes = nil
            finderUsedBytes = nil
            purgeableBytes = nil
            return
        }
        freeSpaceBytes = info.availableCapacity
        finderUsedBytes = info.usedBytes
        purgeableBytes = info.purgeableBytes > 0 ? info.purgeableBytes : nil
        // Hidden space needs a finished scan: a partial tree would misreport
        // the not-yet-visited remainder as hidden.
        if let snapshot = coordinator.snapshot, snapshot.isComplete {
            hiddenSpaceBytes = info.hiddenSpaceBytes(
                scannedBytes: snapshot.treeStore.root.allocatedSize
            )
        } else {
            hiddenSpaceBytes = nil
        }
    }
}
