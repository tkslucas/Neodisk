import AppKit
import Foundation
import Testing
@testable import NeodiskKit
import NeodiskAppModel
@testable import NeodiskUI

/// Cleanup end to end on a real folder: collect, confirm, move (into a stand-in Trash), and the tree shrinks
/// in place.
@MainActor
@Suite(.serialized) struct CleanupModelTests {
    private struct Environment {
        let root: URL
        let fakeTrash: URL
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let defaults: UserDefaults
        let defaultsSuiteName: String

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskCleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
                .resolvingSymlinksInPath()
            root = base.appending(path: "Scan", directoryHint: .isDirectory)
            fakeTrash = base.appending(path: "Trash", directoryHint: .isDirectory)
            cacheDirectory = base.appending(path: "Cache", directoryHint: .isDirectory)
            for directory in [root, fakeTrash, cacheDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            defaultsSuiteName = "NeodiskCleanupTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        }

        @MainActor
        func makeModel(protecting protectedPaths: [String] = [], confirms: Bool = true) -> NeodiskViewModel {
            let model = NeodiskViewModel(
                snapshotCache: cache,
                sidebarFolderStore: SidebarFolderStore(defaults: defaults)
            )
            model.preferences = AppPreferences(defaults: defaults)
            let trash = fakeTrash
            model.cleanup.makePolicy = { TrashSafetyPolicy(protectedPaths: protectedPaths) }
            model.cleanup.confirm = { _ in confirms }
            model.cleanup.trashItem = { url in
                let destination = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
            return model
        }

        @MainActor
        func scan() async throws -> ScanSnapshot {
            var finished: ScanSnapshot?
            for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
                if case .finished(let snapshot) = event { finished = snapshot }
            }
            return try #require(finished)
        }

        func write(_ relativePath: String, bytes: Int) throws {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
        }

        func path(_ relativePath: String) -> String {
            root.appending(path: relativePath).path
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }

    @Test func movingCollectedItemsShrinksTheTreeAndMovesSelectionToASurvivor() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("Old/a.bin", bytes: 400_000)
        try environment.write("Old/Deep/b.bin", bytes: 300_000)
        try environment.write("keep.txt", bytes: 1_000)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        let before = store.root.allocatedSize
        let old = try #require(store.node(id: environment.path("Old")))
        let deep = try #require(store.node(id: environment.path("Old/Deep/b.bin")))

        model.select(deep.id)
        model.cleanup.add([deep])
        // The folder absorbs the item inside it.
        model.cleanup.add([old])
        #expect(model.cleanup.itemIDs == [old.id])
        #expect(model.cleanup.isInsideCollected(deep.id))
        #expect(model.cleanup.totalSize == old.allocatedSize)

        model.cleanup.moveAllToTrash()
        try await waitUntil("moved") { model.store?.node(id: old.id) == nil && !model.cleanup.isMoving }

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: environment.path("keep.txt")))
        #expect(model.store?.root.allocatedSize == before - old.allocatedSize)
        #expect(model.cleanup.isEmpty)
        #expect(model.selectedNodeID == model.store?.root.id)
        #expect(model.cleanup.notice?.kind == .moved)
    }

    @Test func marksTellTheItemFromWhatIsInsideItAndDragsOnlyRealItems() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("Old/Deep/b.bin", bytes: 3_000)
        try environment.write("keep.txt", bytes: 1_000)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        let old = try #require(store.node(id: environment.path("Old")))

        model.cleanup.add([old])
        #expect(model.cleanup.mark(for: old.id) == .collected)
        #expect(model.cleanup.mark(for: environment.path("Old/Deep/b.bin")) == .inside)
        #expect(model.cleanup.mark(for: environment.path("keep.txt")) == .none)
        #expect(model.cleanup.mark(for: old.id).hoverText != nil)
        #expect(CleanupModel.Mark.none.hoverText == nil)
        // Already in with its folder: nothing to add, and ⌘⌫ says why instead of doing nothing.
        let inside = try #require(store.node(id: environment.path("Old/Deep/b.bin")))
        #expect(!model.canToggleCleanup(for: inside))
        model.cleanup.toggle(inside)
        #expect(model.cleanup.itemIDs == [old.id])
        #expect(model.cleanup.notice?.kind == .refused)

        // A drag carries the node and its file URL, for the tree on screen only.
        let item = try #require(NodeDragSource.pasteboardItem(forNodeID: environment.path("keep.txt"), model: model))
        let snapshotID = try #require(model.coordinator.snapshot?.id)
        let pasteboard = NSPasteboard(name: .init("NeodiskDragTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(NodeDragPayload.nodeIDs(on: pasteboard, snapshotID: snapshotID) == [environment.path("keep.txt")])
        #expect(NodeDragPayload.nodeIDs(on: pasteboard, snapshotID: UUID()) == nil)
        #expect(NodeDragSource.pasteboardItem(forNodeID: "/not/scanned", model: model) == nil)
    }

    @Test func refusedItemsNeverJoinAndExplainWhy() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("System Stuff/x.bin", bytes: 10)
        let model = environment.makeModel(protecting: [environment.path("System Stuff")])
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)

        model.cleanup.add([try #require(store.node(id: environment.path("System Stuff")))])
        model.cleanup.add([store.root])
        #expect(model.cleanup.isEmpty)
        #expect(model.cleanup.notice?.kind == .refused)
        // What's inside a protected folder can go.
        model.cleanup.add([try #require(store.node(id: environment.path("System Stuff/x.bin")))])
        #expect(model.cleanup.itemIDs == [environment.path("System Stuff/x.bin")])
    }

    @Test func cancellingTheConfirmationMovesNothing() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 10)
        let model = environment.makeModel(confirms: false)
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let node = try #require(model.store?.node(id: environment.path("a.bin")))

        model.cleanup.add([node])
        model.cleanup.moveAllToTrash()
        try await Task.sleep(for: .milliseconds(100))
        #expect(FileManager.default.fileExists(atPath: node.path))
        #expect(model.store?.node(id: node.id) != nil)
        #expect(model.cleanup.itemIDs == [node.id])
    }

    @Test func changedItemsStayCollectedWithTheirReasonWhileOthersMove() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("edited.txt", bytes: 10)
        try environment.write("gone.txt", bytes: 10)
        try environment.write("fine.txt", bytes: 10)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        let nodes = try ["edited.txt", "gone.txt", "fine.txt"].map {
            try #require(store.node(id: environment.path($0)))
        }
        model.cleanup.add(nodes)

        try environment.write("edited.txt", bytes: 99)
        try FileManager.default.removeItem(atPath: environment.path("gone.txt"))
        model.cleanup.moveAllToTrash()
        try await waitUntil("move finished") {
            model.store?.node(id: environment.path("fine.txt")) == nil && !model.cleanup.isMoving
        }

        #expect(FileManager.default.fileExists(atPath: environment.path("edited.txt")))
        #expect(model.cleanup.itemIDs == [environment.path("edited.txt")])
        #expect(model.cleanup.failures[environment.path("edited.txt")] != nil)
        // Already gone elsewhere: dropped from the tree, not reported as a failure.
        #expect(model.store?.node(id: environment.path("gone.txt")) == nil)
        #expect(model.cleanup.notice?.kind == .failed)
    }

    @Test func turnedOffInSettingsCollectsNothing() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 10)
        let model = environment.makeModel()
        model.preferences?.allowsMovingToTrash = false
        try await waitUntil("preference mirrored") { !model.cleanup.isEnabled }
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let node = try #require(model.store?.node(id: environment.path("a.bin")))

        model.cleanup.add([node])
        #expect(model.cleanup.isEmpty)
        #expect(!model.canToggleCleanup(for: node))
    }

    @Test func aStoppedScanAsksForARescanNotForPatience() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 10)
        let model = environment.makeModel()
        let full = try await environment.scan()
        let stopped = ScanSnapshot(
            target: full.target, treeStore: full.treeStore, startedAt: full.startedAt, finishedAt: nil,
            scanWarnings: [], aggregateStats: full.aggregateStats, isComplete: false
        )
        model.coordinator.replaceCurrentSnapshot(stopped)
        #expect(!model.coordinator.isScanning)
        let reason = try #require(model.cleanup.unavailableReason)
        #expect(reason.contains("Rescan"))
    }

    @Test func aRemovalPersistsWithoutReplacingThePreviousScan() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 10)
        try environment.write("b.bin", bytes: 10)
        let model = environment.makeModel()
        let snapshot = try await environment.scan()
        try await environment.cache.save(snapshot)
        model.coordinator.replaceCurrentSnapshot(snapshot)
        let node = try #require(model.store?.node(id: environment.path("a.bin")))
        model.cleanup.add([node])

        await awaitSnapshotPersist(on: model, of: snapshot.target) {
            model.cleanup.moveAllToTrash()
        }
        let saved = try #require(await environment.cache.loadSnapshot(for: snapshot.target))
        #expect(saved.treeStore.node(id: node.id) == nil)
        #expect(saved.treeStore.node(id: environment.path("b.bin")) != nil)
        // The scan saved before stays the latest's baseline: nothing rotated into the previous slot.
        #expect(await environment.cache.loadPreviousSnapshot(for: snapshot.target) == nil)
    }

    @Test func theChangesListCatchesUpWithAMove() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 10)
        try environment.write("b.bin", bytes: 10)
        try await environment.cache.save(try await environment.scan())
        try environment.write("c.bin", bytes: 20)
        let snapshot = try await environment.scan()
        try await environment.cache.save(snapshot)
        // The diff of these two scans is on disk, as after any scan.
        _ = await environment.cache.comparison(for: snapshot, entryLimit: ChangesModel.entryLimit)
        SidebarFolderStore(defaults: environment.defaults).add(snapshot.target)
        let model = environment.makeModel()
        try await waitUntil("previous scan indexed") {
            model.session.cachedScanInfo[snapshot.target.id]?.hasPreviousSnapshot == true
        }
        model.coordinator.replaceCurrentSnapshot(snapshot)
        let moved = try #require(model.store?.node(id: environment.path("a.bin")))
        model.cleanup.add([moved])

        // The pane reloads the moment the cut tree lands, before its save is written.
        let (release, releaser) = AsyncStream<Void>.makeStream()
        await environment.cache.setEncodeGateForTesting { for await _ in release {} }
        await awaitSnapshotPersist(on: model, of: snapshot.target) {
            model.cleanup.moveAllToTrash()
            Task { @MainActor in
                try await waitUntil("cut on screen") { model.store?.node(id: moved.id) == nil }
                model.changes.loadIfNeeded()
                try await waitUntil("list loaded") { model.changes.list != nil }
                releaser.finish()
            }
        }
        model.changes.loadIfNeeded()
        try await waitUntil("the move shows as a deletion") {
            model.changes.list?.deletedEntries.map(\.path).contains(moved.path) == true
        }
    }

    @Test func duplicateResultsDropWhatWasMovedInsteadOfResetting() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        for name in ["one.bin", "two.bin", "three.bin"] {
            try Data(repeating: 9, count: 1_100_000).write(to: environment.root.appending(path: name))
        }
        let model = environment.makeModel()
        let snapshot = try await environment.scan()
        model.coordinator.replaceCurrentSnapshot(snapshot)
        model.duplicates.startScan()
        try await waitUntil("duplicates found") { model.duplicates.results?.groups.count == 1 }
        let moved = try #require(model.store?.node(id: environment.path("three.bin")))
        model.cleanup.add([moved])

        await awaitSnapshotPersist(on: model, of: snapshot.target) {
            model.cleanup.moveAllToTrash()
        }
        // What the tab does when a new tree lands.
        model.duplicates.loadIfNeeded()
        try await waitUntil("the group lost the moved copy") {
            model.duplicates.results?.groups.first?.nodeIDs == [environment.path("one.bin"), environment.path("two.bin")]
        }
    }

    @Test func aSystemErrorMidBatchKeepsThatItemAndMovesTheRest() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        for name in ["a.bin", "locked.bin", "c.bin"] { try environment.write(name, bytes: 100) }
        let model = environment.makeModel()
        let trash = environment.fakeTrash
        let lockedPath = environment.path("locked.bin")
        model.cleanup.trashItem = { url in
            if url.path == lockedPath { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        model.cleanup.add(try ["a.bin", "locked.bin", "c.bin"].map { try #require(store.node(id: environment.path($0))) })

        model.cleanup.moveAllToTrash()
        try await waitUntil("batch finished") {
            model.store?.node(id: environment.path("c.bin")) == nil && !model.cleanup.isMoving
        }
        #expect(model.store?.node(id: environment.path("a.bin")) == nil)
        #expect(model.store?.node(id: lockedPath) != nil)
        #expect(FileManager.default.fileExists(atPath: lockedPath))
        #expect(model.cleanup.itemIDs == [lockedPath])
        #expect(model.cleanup.failures[lockedPath] != nil)
    }

    @Test func aFailureReasonSurvivesVisitingAnotherLocation() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("A/stuck.bin", bytes: 100)
        try environment.write("B/other.bin", bytes: 100)
        let model = environment.makeModel()
        model.cleanup.trashItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        func scan(_ folder: String) async throws -> ScanSnapshot {
            var finished: ScanSnapshot?
            let target = ScanTarget(url: environment.root.appending(path: folder, directoryHint: .isDirectory))
            for try await event in ScanEngine().scan(target: target, options: ScanOptions()) {
                if case .finished(let snapshot) = event { finished = snapshot }
            }
            return try #require(finished)
        }
        let a = try await scan("A")
        let b = try await scan("B")
        let stuck = environment.path("A/stuck.bin")

        model.coordinator.replaceCurrentSnapshot(a)
        model.cleanup.add([try #require(a.treeStore.node(id: stuck))])
        model.cleanup.moveAllToTrash()
        try await waitUntil("move failed") { model.cleanup.failures[stuck] != nil && !model.cleanup.isMoving }
        model.coordinator.replaceCurrentSnapshot(b)
        model.cleanup.add([try #require(b.treeStore.node(id: environment.path("B/other.bin")))])
        // Any tree change of B (an expansion, a move) reconciles its pile.
        model.coordinator.replaceCurrentSnapshot(b)
        model.coordinator.replaceCurrentSnapshot(a)

        #expect(model.cleanup.itemIDs == [stuck])
        #expect(model.cleanup.failures[stuck] != nil)
    }

    @Test func aRescanThatReplacesACollectedItemDropsIt() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 100)
        try environment.write("b.bin", bytes: 100)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        model.cleanup.add(try ["a.bin", "b.bin"].map { try #require(store.node(id: environment.path($0))) })

        try FileManager.default.removeItem(atPath: environment.path("a.bin"))
        try FileManager.default.createDirectory(atPath: environment.path("a.bin"), withIntermediateDirectories: true)
        try environment.write("a.bin/huge.bin", bytes: 4_000_000)
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())

        #expect(model.cleanup.itemIDs == [environment.path("b.bin")])
        #expect(model.cleanup.notice?.kind == .info)
    }

    @Test func smallerItemsCellsDontOfferToCollectTheirFolder() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("Folder/a.bin", bytes: 100)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let folder = try #require(model.store?.node(id: environment.path("Folder")))
        let title = NSLocalizedString("Add to Cleanup", comment: "")
        let full = try #require(NSMenu.fileNodeActions(for: folder, model: model))
        let aggregate = try #require(NSMenu.fileNodeActions(for: folder, model: model, includeCleanup: false))
        #expect(full.items.contains { $0.title == title })
        #expect(!aggregate.items.contains { $0.title == title })
    }
}
