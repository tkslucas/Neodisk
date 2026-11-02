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
        // A top-level item's survivor is the root: nothing selected, not a ring around the whole map.
        #expect(model.selectedNodeID == nil)
        #expect(model.cleanup.notice?.kind == .moved)
    }

    @Test func directMoveConfirmsOnlyTheSelectionAndLeavesOtherCollectedItems() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        for name in ["Old/a.bin", "Old/b.bin", "selected.bin", "queued.bin"] {
            try environment.write(name, bytes: 100)
        }
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        let old = try #require(store.node(id: environment.path("Old")))
        let child = try #require(store.node(id: environment.path("Old/a.bin")))
        let selected = try #require(store.node(id: environment.path("selected.bin")))
        let queued = try #require(store.node(id: environment.path("queued.bin")))
        model.cleanup.add([queued, child])
        model.selection.replace(with: [child.id, old.id, selected.id], primary: selected.id)
        var confirmation: TrashConfirmation?
        model.cleanup.confirm = { [weak model] in
            confirmation = $0
            // The request captures the selection before presenting the sheet.
            model?.select(queued.id)
            return true
        }

        #expect(model.canMoveSelectionToTrash)
        model.moveSelectionToTrash()
        try await waitUntil("selected items moved") {
            model.store?.node(id: selected.id) == nil && !model.cleanup.isMoving
        }

        #expect(confirmation?.paths == TrashConfirmation(nodes: [old, selected]).paths)
        #expect(confirmation?.title == TrashConfirmation(nodes: [old, selected]).title)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(FileManager.default.fileExists(atPath: queued.path))
        #expect(model.cleanup.itemIDs == [queued.id])
    }

    @Test func cancellingADirectMoveLeavesTheCollectionUnchangedAndPreventsASecondSheet() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("selected.bin", bytes: 100)
        try environment.write("queued.bin", bytes: 100)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let selected = try #require(model.store?.node(id: environment.path("selected.bin")))
        let queued = try #require(model.store?.node(id: environment.path("queued.bin")))
        model.cleanup.add([queued])
        model.select(selected.id)
        var confirmations = 0
        var dismiss: CheckedContinuation<Bool, Never>?
        model.cleanup.confirm = { _ in
            confirmations += 1
            return await withCheckedContinuation { dismiss = $0 }
        }

        model.moveSelectionToTrash()
        #expect(!model.canMoveSelectionToTrash)
        #expect(!model.cleanup.canMoveToTrash)
        model.cleanup.moveToTrash([selected])
        try await waitUntil("confirmation presented") { dismiss != nil }
        dismiss?.resume(returning: false)
        try await waitUntilAsync("confirmation dismissed") {
            await MainActor.run { model.canMoveSelectionToTrash }
        }

        #expect(confirmations == 1)
        #expect(model.cleanup.itemIDs == [queued.id])
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(model.store?.node(id: selected.id) != nil)
        #expect(!model.cleanup.isMoving)
    }

    @Test func directlyMovingAChildDoesNotMoveItsCollectedParentOrSibling() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("Folder/selected.bin", bytes: 100)
        try environment.write("Folder/keep.bin", bytes: 100)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let folder = try #require(model.store?.node(id: environment.path("Folder")))
        let selected = try #require(model.store?.node(id: environment.path("Folder/selected.bin")))
        model.cleanup.add([folder])
        model.select(selected.id)

        #expect(model.canMoveSelectionToTrash)
        model.moveSelectionToTrash()
        try await waitUntil("child moved") { model.store?.node(id: selected.id) == nil && !model.cleanup.isMoving }

        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: environment.path("Folder/keep.bin")))
        #expect(model.cleanup.itemIDs == [folder.id])
        #expect(model.cleanup.totalSize == model.store?.node(id: folder.id)?.allocatedSize)
    }

    @Test func directMoveKeepsChangedItemsForRetryAndMovesTheOthers() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        for name in ["edited.bin", "fine.bin", "queued.bin"] { try environment.write(name, bytes: 100) }
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let queued = try #require(model.store?.node(id: environment.path("queued.bin")))
        model.cleanup.add([queued])
        model.selection.replace(with: [environment.path("edited.bin"), environment.path("fine.bin")], primary: environment.path("fine.bin"))
        // The live file check must still run after confirmation, including for the direct button.
        model.cleanup.confirm = { _ in
            try? environment.write("edited.bin", bytes: 200)
            return true
        }

        model.moveSelectionToTrash()
        try await waitUntil("direct batch finished") {
            model.store?.node(id: environment.path("fine.bin")) == nil && !model.cleanup.isMoving
        }

        #expect(FileManager.default.fileExists(atPath: environment.path("edited.bin")))
        #expect(FileManager.default.fileExists(atPath: queued.path))
        #expect(model.cleanup.itemIDs == [queued.id, environment.path("edited.bin")])
        #expect(model.cleanup.failures[environment.path("edited.bin")] != nil)
        #expect(model.cleanup.notice?.kind == .failed)
    }

    @Test func directMoveRechecksThePolicyAfterConfirmation() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("selected.bin", bytes: 100)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let selected = try #require(model.store?.node(id: environment.path("selected.bin")))
        model.select(selected.id)
        model.cleanup.confirm = { [weak model] _ in
            model?.cleanup.makePolicy = { TrashSafetyPolicy(protectedPaths: [selected.path]) }
            return true
        }

        model.moveSelectionToTrash()
        try await waitUntil("fresh policy refused move") {
            model.cleanup.failures[selected.id] != nil && !model.cleanup.isMoving
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(model.cleanup.itemIDs == [selected.id])
    }

    @Test func aNewSnapshotDuringDirectConfirmationCancelsTheMove() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("selected.bin", bytes: 100)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let replacement = try await environment.scan()
        let selected = try #require(model.store?.node(id: environment.path("selected.bin")))
        model.select(selected.id)
        var confirmed = false
        model.cleanup.confirm = { [weak model] _ in
            model?.coordinator.replaceCurrentSnapshot(replacement)
            confirmed = true
            return true
        }

        model.moveSelectionToTrash()
        try await waitUntilAsync("confirmation returned") {
            await MainActor.run { confirmed && model.cleanup.canMoveToTrash([selected]) }
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(model.store?.node(id: selected.id) != nil)
        #expect(model.cleanup.isEmpty)
        #expect(!model.cleanup.isMoving)
    }

    @Test func directMoveRefusesAProtectedSelectionWithoutMovingAnAllowedSubset() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("keep.bin", bytes: 100)
        try environment.write("protected.bin", bytes: 100)
        let model = environment.makeModel(protecting: [environment.path("protected.bin")])
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        model.selection.replace(with: [environment.path("keep.bin"), environment.path("protected.bin")], primary: environment.path("protected.bin"))
        var confirmed = false
        model.cleanup.confirm = { _ in confirmed = true; return true }

        model.moveSelectionToTrash()
        #expect(!confirmed)
        #expect(model.cleanup.notice?.kind == .refused)
        #expect(model.cleanup.isEmpty)
        #expect(FileManager.default.fileExists(atPath: environment.path("keep.bin")))
        #expect(FileManager.default.fileExists(atPath: environment.path("protected.bin")))
    }

    @Test func directMoveIsUnavailableForEmptyRootScanningStoppedImportedAndDisabledSelections() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("selected.bin", bytes: 100)
        let model = environment.makeModel()
        #expect(!model.canMoveSelectionToTrash)
        let full = try await environment.scan()
        model.coordinator.replaceCurrentSnapshot(full)
        #expect(!model.canMoveSelectionToTrash)
        model.select(full.root.id)
        #expect(!model.canMoveSelectionToTrash)
        let selected = try #require(model.store?.node(id: environment.path("selected.bin")))
        model.select(selected.id)
        #expect(model.canMoveSelectionToTrash)

        model.coordinator.phase = .scanning
        #expect(!model.cleanup.canMoveToTrash([selected]))
        model.coordinator.phase = .displaying

        for source in [ScanSnapshotSource.live, .imported(ImportedSnapshotContext(
            sourceURL: environment.root.appending(path: "scan.neodisk"), pathMode: .absolute, liveActionCapability: .disabled
        ))] {
            model.coordinator.replaceCurrentSnapshot(ScanSnapshot(
                target: full.target, treeStore: full.treeStore, startedAt: full.startedAt, finishedAt: full.finishedAt,
                scanWarnings: [], aggregateStats: full.aggregateStats, isComplete: source.isImported, source: source
            ))
            model.select(selected.id)
            #expect(!model.canMoveSelectionToTrash)
        }
        model.coordinator.replaceCurrentSnapshot(full)
        model.select(selected.id)
        model.cleanup.setEnabled(false)
        #expect(!model.canMoveSelectionToTrash)
        model.cleanup.moveToTrash([selected])
        #expect(FileManager.default.fileExists(atPath: selected.path))
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
        #expect(!model.canToggleCleanup(for: [inside]))
        model.cleanup.toggle([inside])
        #expect(model.cleanup.itemIDs == [old.id])
        #expect(model.cleanup.notice?.kind == .refused)
        // Its menu item is off and says why.
        #expect(model.cleanupMenuHelp(for: [inside]) == CleanupModel.Mark.inside.hoverText)
        #expect(model.canToggleCleanup(for: [old]))
        #expect(model.cleanupMenuHelp(for: [old]) == nil)

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

    @Test func aPartlyRefusedSelectionSaysWhatDidntJoin() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        for name in ["a.bin", "b.bin", "c.bin", "Keep1/x.bin", "Keep2/y.bin", "Notes.rtfd/TXT.rtf"] {
            try environment.write(name, bytes: 10)
        }
        let model = environment.makeModel(protecting: [environment.path("Keep1"), environment.path("Keep2")])
        // Packages opened as folders (the Settings option), so what's inside one is in the tree.
        var options = ScanOptions()
        options.treatPackagesAsDirectories = true
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: environment.root), options: options) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        guard let finished else {
            Issue.record("the scan didn't finish")
            return
        }
        model.coordinator.replaceCurrentSnapshot(finished)
        let store = try #require(model.store)
        let nodes = try ["a.bin", "Keep1", "b.bin", "Keep2", "c.bin"].map { try #require(store.node(id: environment.path($0))) }

        model.cleanup.add(nodes)
        #expect(model.cleanup.itemIDs.count == 3)
        let reason = TrashRefusal.protectedLocation.localizedReason
        #expect(model.cleanup.notice?.kind == .refused)
        #expect(model.cleanup.notice?.text == "Added 3 items. 2 items can't go to the Trash. " + reason)

        // Inside a package is refused, with that reason alone; the package itself can go.
        let inside = try #require(store.node(id: environment.path("Notes.rtfd/TXT.rtf")))
        model.cleanup.add([inside])
        #expect(model.cleanup.notice?.text == TrashRefusal.insidePackage.localizedReason)
        model.cleanup.add([try #require(store.node(id: environment.path("Notes.rtfd")))])
        #expect(model.cleanup.itemIDs.count == 4)
    }

    /// ⌘A in the outline takes its root row too: the refused root mustn't swallow the items selected inside it.
    @Test func aRefusedFolderInTheSelectionDoesntTakeItsSelectedItemsWithIt() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        for name in ["a.bin", "Keep/b.bin", "Keep/c.bin", "Old/d.bin"] {
            try environment.write(name, bytes: 10)
        }
        let model = environment.makeModel(protecting: [environment.path("Keep")])
        let policyBuilds = PolicyBuildCounter()
        let makePolicy = model.cleanup.makePolicy
        // Only main-thread builds count: the warm-up when the scan lands runs in the background.
        model.cleanup.makePolicy = {
            if Thread.isMainThread { policyBuilds.increment() }
            return makePolicy()
        }
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let store = try #require(model.store)
        let nodes = try ["a.bin", "Keep", "Keep/b.bin", "Old", "Old/d.bin"]
            .map { try #require(store.node(id: environment.path($0))) }

        // The menu title reads only the tree (Keep's path isn't checked until the add), never the disk.
        #expect(model.cleanupMenuTitle(for: [store.root] + nodes) == "Add 3 Items to Cleanup")
        #expect(policyBuilds.count == 0)
        model.cleanup.toggle([store.root] + nodes)
        #expect(model.cleanup.itemIDs == ["a.bin", "Keep/b.bin", "Old"].map(environment.path))
        // Old/d.bin goes with Old: only the root and Keep are refused.
        #expect(model.cleanup.notice?.text
            == "Added 3 items. 2 items can't go to the Trash. " + TrashRefusal.scanRoot.localizedReason)
        // Pressed again (Select All takes the root row too), it takes them out.
        let collected = try ["a.bin", "Keep/b.bin", "Old", "Old/d.bin"]
            .map { try #require(store.node(id: environment.path($0))) }
        #expect(model.cleanupMenuTitle(for: [store.root] + collected) == "Remove 3 Items from Cleanup")
        model.cleanup.toggle([store.root] + collected)
        #expect(model.cleanup.isEmpty)
    }

    private final class PolicyBuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
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
        #expect(!model.canToggleCleanup(for: [node]))
    }

    @Test func turningItOffHidesWhatWasCollectedUntilItsBackOn() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        try environment.write("a.bin", bytes: 10)
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(try await environment.scan())
        let node = try #require(model.store?.node(id: environment.path("a.bin")))
        model.cleanup.add([node])
        #expect(model.cleanup.mark(for: node.id) == .collected)

        // The panel goes with the setting, so nothing may stay marked without a way to see or clear it.
        model.preferences?.allowsMovingToTrash = false
        try await waitUntil("preference mirrored") { !model.cleanup.isEnabled }
        #expect(model.cleanup.isEmpty)
        #expect(model.cleanup.mark(for: node.id) == .none)
        #expect(model.selectionSummary == nil || model.selectionSummary?.inCleanup == 0)

        model.preferences?.allowsMovingToTrash = true
        try await waitUntil("preference mirrored") { model.cleanup.isEnabled }
        #expect(model.cleanup.mark(for: node.id) == .collected)
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
