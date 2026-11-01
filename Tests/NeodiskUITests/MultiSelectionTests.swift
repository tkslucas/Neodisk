import AppKit
import Foundation
import Testing
@testable import NeodiskKit
import NeodiskAppModel
@testable import NeodiskUI

/// Several selected items on a real scanned folder: what menus, ⌘⌫, drags, Quick Look and the status line do
/// with them.
@MainActor
@Suite(.serialized) struct MultiSelectionTests {
    private struct Environment {
        let root: URL
        let cache: ScanSnapshotCache
        let defaults: UserDefaults
        let defaultsSuiteName: String

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appending(path: "NeodiskMultiSelectionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
                .resolvingSymlinksInPath()
            root = base.appending(path: "Scan", directoryHint: .isDirectory)
            let cacheDirectory = base.appending(path: "Cache", directoryHint: .isDirectory)
            for directory in [root, cacheDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            defaultsSuiteName = "NeodiskMultiSelectionTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            for (path, bytes) in [
                ("Old/a.bin", 400_000), ("Old/b.bin", 200_000), ("Old/Deep/c.bin", 100_000),
                ("keep.txt", 50_000), ("other.bin", 30_000),
            ] {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(count: bytes).write(to: url)
            }
        }

        @MainActor
        func makeModel() async throws -> NeodiskViewModel {
            let model = NeodiskViewModel(
                snapshotCache: cache,
                sidebarFolderStore: SidebarFolderStore(defaults: defaults)
            )
            model.preferences = AppPreferences(defaults: defaults)
            model.cleanup.makePolicy = { TrashSafetyPolicy(protectedPaths: []) }
            var finished: ScanSnapshot?
            for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
                if case .finished(let snapshot) = event { finished = snapshot }
            }
            let snapshot: ScanSnapshot = try #require(finished)
            model.coordinator.replaceCurrentSnapshot(snapshot)
            return model
        }

        func path(_ relativePath: String) -> String {
            root.appending(path: relativePath).path
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }

    private func nodes(_ paths: [String], in model: NeodiskViewModel) throws -> [FileNodeRecord] {
        try paths.map { try #require(model.store?.node(id: $0)) }
    }

    @Test func cleanupTogglesTowardAddingUntilEverythingIsIn() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        let old = environment.path("Old"), a = environment.path("Old/a.bin")
        let keep = environment.path("keep.txt"), other = environment.path("other.bin")
        let selected = try nodes([a, old, keep], in: model)

        // A folder and something in it add as one item.
        #expect(model.cleanup.toggle(for: selected) == .add([old, keep]))
        #expect(model.cleanupMenuTitle(for: selected) == "Add 2 Items to Cleanup")
        model.cleanup.toggle(selected)
        #expect(model.cleanup.itemIDs == [old, keep])

        // Everything in (alone or with its folder): the collected ones come out.
        #expect(model.cleanup.toggle(for: selected) == .remove([old, keep]))
        #expect(model.cleanupMenuTitle(for: selected) == "Remove 2 Items from Cleanup")

        // Mixed: the one not in yet joins; nothing leaves.
        let mixed = try nodes([keep, other], in: model)
        #expect(model.cleanup.toggle(for: mixed) == .add([other]))
        #expect(model.cleanupMenuTitle(for: mixed) == "Add to Cleanup")
        model.cleanup.toggle(mixed)
        #expect(Set(model.cleanup.itemIDs) == [old, keep, other])

        // Only items inside a collected folder: nothing to do.
        let inside = try nodes([a, environment.path("Old/b.bin")], in: model)
        #expect(model.cleanup.toggle(for: inside) == .none)
        #expect(!model.canToggleCleanup(for: inside))
        #expect(model.cleanupMenuHelp(for: inside) == CleanupModel.Mark.inside.hoverText)
    }

    @Test func contextMenuActsOnTheSelectionOnlyWhenClickedInsideIt() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        let keep = try #require(model.store?.node(id: environment.path("keep.txt")))
        let other = try #require(model.store?.node(id: environment.path("other.bin")))
        let old = try #require(model.store?.node(id: environment.path("Old")))
        model.selection.replace(with: [keep.id, other.id], primary: other.id)

        #expect(model.actionTargets(clicked: keep).map(\.id) == [keep.id, other.id])
        #expect(model.actionTargets(clicked: old).map(\.id) == [old.id])
        // A lone selected item is just the clicked item.
        model.select(keep.id)
        #expect(model.actionTargets(clicked: keep).map(\.id) == [keep.id])

        let menu = try #require(NSMenu.fileNodeActions(for: other, model: model))
        #expect(menu.items.contains { $0.title == "Copy Path" })
        model.selection.replace(with: [keep.id, other.id], primary: other.id)
        let multiMenu = try #require(NSMenu.fileNodeActions(for: other, model: model))
        #expect(multiMenu.items.contains { $0.title == "Copy Paths" })
        #expect(multiMenu.items.contains { $0.title == "Add 2 Items to Cleanup" })
    }

    @Test func statusSummaryCountsANestedItemOnceInTheSize() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        let store = try #require(model.store)
        let old = try #require(store.node(id: environment.path("Old")))
        let keep = try #require(store.node(id: environment.path("keep.txt")))
        model.selection.replace(
            with: [environment.path("Old/a.bin"), old.id, keep.id], primary: keep.id
        )
        let summary = try #require(model.selectionSummary)
        #expect(summary.count == 3)
        #expect(summary.totalSize == old.allocatedSize + keep.allocatedSize)
        #expect(summary.inCleanup == 0)

        model.cleanup.add([old])
        #expect(model.selectionSummary?.inCleanup == 2)
        #expect(StatusBar.countText(3) == "3 items selected")
        #expect(StatusBar.inCleanupText(2, of: 3) == "2 in Cleanup")
        #expect(StatusBar.inCleanupText(3, of: 3) == "All in Cleanup")
    }

    @Test func aDraggedItemInsideASelectedFolderTravelsWithIt() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        let old = environment.path("Old"), a = environment.path("Old/a.bin"), keep = environment.path("keep.txt")
        model.selection.replace(with: [old, a, keep], primary: keep)
        #expect(NodeDragSource.pasteboardItem(forNodeID: old, model: model) != nil)
        #expect(NodeDragSource.pasteboardItem(forNodeID: a, model: model) == nil)
        #expect(NodeDragSource.pasteboardItem(forNodeID: keep, model: model) != nil)
        // Not selected: a drag of that row alone still carries it.
        model.select(keep)
        #expect(NodeDragSource.pasteboardItem(forNodeID: a, model: model) != nil)
    }

    @Test func listSelectionKeepsHiddenItemsOnlyForExtendingGestures() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        let a = environment.path("Old/a.bin"), keep = environment.path("keep.txt")
        let other = environment.path("other.bin")
        model.select(a)
        let shown: Set<String> = [keep, other]
        model.select(fromList: ListSelection(ids: [keep, other], primary: other, extending: true)) {
            shown.contains($0)
        }
        #expect(model.selection.ids == [a, keep, other])
        #expect(model.selectedNodeID == other)
        model.select(fromList: ListSelection(ids: [keep], primary: keep, extending: false)) { shown.contains($0) }
        #expect(model.selection.ids == [keep])
    }

    @Test func selectAllInTheMapPicksTheRootsChildren() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        model.selectAllInMap()
        #expect(Set(model.selection.ids) == [
            environment.path("Old"), environment.path("keep.txt"), environment.path("other.bin"),
        ])
        model.zoomRootID = environment.path("Old")
        model.selectAllInMap()
        #expect(Set(model.selection.ids) == [
            environment.path("Old/a.bin"), environment.path("Old/b.bin"), environment.path("Old/Deep"),
        ])
    }

    @Test func removalKeepsTheRestOfAMultiSelection() async throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let model = try await environment.makeModel()
        let store = try #require(model.store)
        let a = environment.path("Old/a.bin"), keep = environment.path("keep.txt")
        model.selection.replace(with: [a, keep], primary: a)
        model.prepareForRemoval(of: [environment.path("Old")], in: store)
        #expect(model.selection.ids == [keep])
    }

    @Test func quickLookShowsEveryPreviewableItemStartingAtTheCurrentOne() {
        let first = makeTestFileNode(id: "/tmp/a.pdf", name: "a.pdf")
        let gone = makeTestFileNode(id: "/tmp/gone.pdf", name: "gone.pdf")
        let third = makeTestFileNode(id: "/tmp/c.pdf", name: "c.pdf")
        let items = QuickLookPresenter.previewItems(
            for: [first, gone, third], current: third, fileExists: { $0 != "/tmp/gone.pdf" }
        )
        #expect(items.urls.map(\.path) == ["/tmp/a.pdf", "/tmp/c.pdf"])
        #expect(items.index == 1)
        #expect(QuickLookPresenter.previewItems(for: [gone], current: gone, fileExists: { _ in false }).urls.isEmpty)
    }

    @Test func selectedRowsJoinAtTheCornersTheyShare() {
        let rect = NSRect(x: 10, y: 0, width: 200, height: 24)
        #expect(OutlineTableRowView.squaredHalves(of: rect, top: false, bottom: false, isFlipped: true).isEmpty)
        let both = OutlineTableRowView.squaredHalves(of: rect, top: true, bottom: true, isFlipped: true)
        #expect(both == [NSRect(x: 10, y: 0, width: 200, height: 12), NSRect(x: 10, y: 12, width: 200, height: 12)])
        // Unflipped, the top half is the upper one.
        #expect(OutlineTableRowView.squaredHalves(of: rect, top: true, bottom: false, isFlipped: false)
            == [NSRect(x: 10, y: 12, width: 200, height: 12)])
    }
}
