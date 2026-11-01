import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

@Suite struct NodeSelectionTests {
    /// /s ─ a/ ─ a1, a2 ; b ; c/ ─ c1
    private func makeStore() -> FileTreeStore {
        let a1 = makeTestFileNode(id: "/s/a/a1", name: "a1", size: 10)
        let a2 = makeTestFileNode(id: "/s/a/a2", name: "a2", size: 5)
        let a = makeTestDirectoryNode(id: "/s/a", name: "a", children: [a1, a2])
        let b = makeTestFileNode(id: "/s/b", name: "b", size: 8)
        let c1 = makeTestFileNode(id: "/s/c/c1", name: "c1", size: 3)
        let c = makeTestDirectoryNode(id: "/s/c", name: "c", children: [c1])
        let root = makeTestDirectoryNode(id: "/s", name: "s", children: [a, b, c])
        return FileTreeStore(
            root: root,
            childrenByID: ["/s": [a, b, c], "/s/a": [a1, a2], "/s/c": [c1]]
        )
    }

    @Test func replaceKeepsOneItemAsPrimary() {
        var selection = NodeSelection()
        #expect(selection.isEmpty && selection.primaryID == nil)
        selection.replace(with: "/s/b")
        #expect(selection.ids == ["/s/b"] && selection.primaryID == "/s/b")
        selection.replace(with: nil)
        #expect(selection.isEmpty && selection.primaryID == nil)
    }

    @Test func replaceWithManyDropsDuplicatesAndPicksThePrimary() {
        var selection = NodeSelection()
        selection.replace(with: ["/s/a", "/s/b", "/s/a", "/s/c"], primary: "/s/b")
        #expect(selection.ids == ["/s/a", "/s/b", "/s/c"])
        #expect(selection.primaryID == "/s/b")
        // A primary that isn't among them falls back to the last.
        selection.replace(with: ["/s/a", "/s/c"], primary: "/s/b")
        #expect(selection.primaryID == "/s/c")
    }

    @Test func toggleAddsAsPrimaryAndRemovesWithFallback() {
        var selection = NodeSelection()
        selection.toggle("/s/a")
        selection.toggle("/s/b")
        selection.toggle("/s/c")
        #expect(selection.ids == ["/s/a", "/s/b", "/s/c"] && selection.primaryID == "/s/c")
        selection.toggle("/s/c")
        #expect(selection.ids == ["/s/a", "/s/b"] && selection.primaryID == "/s/b")
        selection.toggle("/s/a")
        #expect(selection.ids == ["/s/b"] && selection.primaryID == "/s/b")
        selection.toggle("/s/b")
        #expect(selection.isEmpty && selection.primaryID == nil)
    }

    @Test func addingAMemberOnlyMovesThePrimary() {
        var selection = NodeSelection(["/s/a", "/s/b"])
        selection.add("/s/a")
        #expect(selection.ids == ["/s/a", "/s/b"] && selection.primaryID == "/s/a")
    }

    @Test func revisionMovesOnlyOnRealChanges() {
        var selection = NodeSelection()
        selection.replace(with: "/s/a")
        let revision = selection.revision
        selection.replace(with: "/s/a")
        selection.add("/s/a")
        selection.remove(["/s/zzz"])
        #expect(selection.revision == revision)
        selection.add("/s/b")
        #expect(selection.revision != revision)
    }

    @Test func plainListClickReplacesEverything() {
        var selection = NodeSelection(["/s/a/a1", "/s/b"])
        selection.applyList(selected: ["/s/c"], primary: "/s/c", extending: false) { _ in true }
        #expect(selection.ids == ["/s/c"])
    }

    @Test func extendingListGestureKeepsWhatTheListDoesNotShow() {
        // a1 is in a collapsed folder: the list can't show it, so ⌘-clicking c keeps it.
        var selection = NodeSelection(["/s/a/a1", "/s/b"])
        let shown: Set<String> = ["/s/a", "/s/b", "/s/c"]
        selection.applyList(selected: ["/s/b", "/s/c"], primary: "/s/c", extending: true) { shown.contains($0) }
        #expect(selection.ids == ["/s/a/a1", "/s/b", "/s/c"])
        #expect(selection.primaryID == "/s/c")
        // ⌘-clicking b off drops it, since the list shows it.
        selection.applyList(selected: ["/s/c"], primary: "/s/c", extending: true) { shown.contains($0) }
        #expect(selection.ids == ["/s/a/a1", "/s/c"])
    }

    @Test func contextMenuTargetsFollowTheClickedItem() {
        let selection = NodeSelection(["/s/a", "/s/b"])
        #expect(selection.targets(clicked: "/s/b") == ["/s/a", "/s/b"])
        #expect(selection.targets(clicked: "/s/c") == ["/s/c"])
        #expect(selection.targets(clicked: nil) == ["/s/a", "/s/b"])
    }

    @Test func topLevelLeavesOutItemsInsideSelectedFolders() {
        let store = makeStore()
        let selection = NodeSelection(["/s/a/a1", "/s/a", "/s/b", "/s/gone"])
        #expect(selection.topLevelIDs(in: store) == ["/s/a", "/s/b"])
        #expect(NodeSelection(["/s/gone"]).topLevelIDs(in: store).isEmpty)
    }

    @Test func reconcileDropsWhatLeftTheTree() {
        let store = makeStore()
        var selection = NodeSelection(["/s/a", "/s/old", "/s/b"], primary: "/s/old")
        let dropped = selection.reconcile(with: store)
        #expect(dropped)
        #expect(selection.ids == ["/s/a", "/s/b"] && selection.primaryID == "/s/b")
        let droppedAgain = selection.reconcile(with: store)
        #expect(!droppedAgain)
    }

    @Test func removalDropsItemsInsideAndKeepsTheRest() {
        let store = makeStore()
        var selection = NodeSelection(["/s/a/a1", "/s/b"], primary: "/s/a/a1")
        selection.prepareForRemoval(of: ["/s/a"], in: store)
        #expect(selection.ids == ["/s/b"] && selection.primaryID == "/s/b")
    }

    @Test func removalOfEverythingLandsOnThePrimarysFolder() {
        let store = makeStore()
        var selection = NodeSelection(["/s/c/c1", "/s/a/a2"], primary: "/s/a/a2")
        selection.prepareForRemoval(of: ["/s/c/c1", "/s/a/a2"], in: store)
        #expect(selection.ids == ["/s/a"] && selection.primaryID == "/s/a")
    }

    @Test func aPressOnOrInsideASelectedItemDragsTheSelection() {
        let store = makeStore()
        let selection = NodeSelection(["/s/a", "/s/a/a1", "/s/b"])
        // On a member, or inside a selected folder: the whole selection, top-level.
        #expect(selection.dragIDs(pressing: "/s/b", mapRootID: "/s", in: store) == ["/s/a", "/s/b"])
        #expect(selection.dragIDs(pressing: "/s/a/a2", mapRootID: "/s", in: store) == ["/s/a", "/s/b"])
        // Elsewhere: the pressed item goes alone.
        #expect(selection.dragIDs(pressing: "/s/c/c1", mapRootID: "/s", in: store) == nil)
        // Drilled into a selected folder, everything is inside it: that doesn't count as pressing it.
        #expect(NodeSelection(["/s/a"]).dragIDs(pressing: "/s/a/a1", mapRootID: "/s/a", in: store) == nil)
        #expect(NodeSelection().dragIDs(pressing: "/s/b", mapRootID: "/s", in: store) == nil)
    }

    @Test func mapClicksToggleWithCommandOrShift() {
        #expect(MapClick(command: false, shift: false) == .replace)
        #expect(MapClick(command: true, shift: false) == .toggle)
        #expect(MapClick(command: false, shift: true) == .toggle)
    }

    @Test func containsAncestorFindsASelectedFolderAbove() {
        let store = makeStore()
        let selection = NodeSelection(["/s/a", "/s/b"])
        #expect(selection.containsAncestor(of: "/s/a/a1", in: store))
        #expect(!selection.containsAncestor(of: "/s/c/c1", in: store))
        #expect(!NodeSelection(["/s/a"]).containsAncestor(of: "/s/a/a1", in: store))
    }
}
