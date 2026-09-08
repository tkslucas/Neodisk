import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@MainActor
@Suite(.serialized) struct FreeSpaceModelTests {
    @Test func reusesCapacityUntilSnapshotChangesOrVolumeInvalidates() async throws {
        let coordinator = ScanCoordinator()
        let loader = CapacityLoader()
        let model = FreeSpaceModel(coordinator: coordinator, cloudScan: nil, loadVolume: loader.load)
        let target = makeTestTarget("/volume", kind: .volume)
        let root = makeTestDirectoryNode(id: target.id, name: "volume", children: [])
        let store = FileTreeStore(root: root)
        coordinator.restoreCompletedSnapshot(makeTestSnapshot(target: target, root: root, store: store))
        model.update()
        try await waitUntil("capacity loaded") { model.freeSpaceBytes == 40 }
        for _ in 0..<20 { model.update() }
        #expect(await loader.count == 1)
        #expect(model.finderUsedBytes == 60)
        #expect(model.hiddenSpaceBytes == 60)
        coordinator.restoreCompletedSnapshot(makeTestSnapshot(target: target, root: root, store: store))
        model.update()
        try await waitUntil("completion refresh") { model.freeSpaceBytes == 41 }
        model.invalidateVolume()
        try await waitUntil("mount refresh") { model.freeSpaceBytes == 42 }
        #expect(await loader.count == 3)
    }

    @Test func lateVolumeResultCannotPopulateFolderSpace() async throws {
        let coordinator = ScanCoordinator()
        let loader = CapacityLoader()
        let model = FreeSpaceModel(coordinator: coordinator, cloudScan: nil, loadVolume: loader.load)
        let volume = makeTestTarget("/volume", kind: .volume)
        let root = makeTestDirectoryNode(id: volume.id, name: "volume", children: [])
        let store = FileTreeStore(root: root)
        coordinator.restoreCompletedSnapshot(makeTestSnapshot(target: volume, root: root, store: store))
        model.update()
        let folder = makeTestTarget("/folder")
        coordinator.restoreCompletedSnapshot(makeTestSnapshot(target: folder, root: root, store: store))
        model.update()
        await Task.yield()
        #expect(model.freeSpaceBytes == nil)
        #expect(model.finderUsedBytes == nil)
        #expect(model.hiddenSpaceBytes == nil)
    }
}

private actor CapacityLoader {
    private(set) var count = 0
    func load(_ url: URL) async -> VolumeSpaceInfo? {
        let available = 40 + count
        count += 1
        return VolumeSpaceInfo(totalCapacity: 100, availableCapacity: Int64(available), strictlyFreeCapacity: 30)
    }
}
