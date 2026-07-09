import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Keyboard drill navigation on the view model (⌘↓ / ⌘↑). Spatial arrow
/// movement lives in the controller and needs a rendered scene; the drill
/// logic here is pure tree/root state and is checked directly.
@MainActor
@Suite(.serialized) struct TreemapKeyboardNavTests {
    private struct Fixture {
        let model: NeodiskViewModel
        let root: FileNodeRecord
        let sub: FileNodeRecord
        let big: FileNodeRecord
        let small: FileNodeRecord
        let loose: FileNodeRecord
        let area: FileNodeRecord
        let left: FileNodeRecord
        let right: FileNodeRecord
        let leftFile: FileNodeRecord
        let rightFile: FileNodeRecord
        let cacheDirectory: URL
        let defaults: UserDefaults
        let defaultsSuiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }

    /// root ─┬─ sub ──┬─ big.bin (100)
    ///       │        └─ small.bin (10)
    ///       ├─ loose.txt (5)
    ///       └─ area ─┬─ left ── lfile.bin (50)
    ///                └─ right ─ rfile.bin (50)
    private func makeFixture() throws -> Fixture {
        let big = makeTestFileNode(id: "/root/sub/big.bin", name: "big.bin", size: 100)
        let small = makeTestFileNode(id: "/root/sub/small.bin", name: "small.bin", size: 10)
        let sub = makeTestDirectoryNode(id: "/root/sub", name: "sub", children: [big, small])
        let loose = makeTestFileNode(id: "/root/loose.txt", name: "loose.txt", size: 5)
        let leftFile = makeTestFileNode(id: "/root/area/left/lfile.bin", name: "lfile.bin", size: 50)
        let rightFile = makeTestFileNode(id: "/root/area/right/rfile.bin", name: "rfile.bin", size: 50)
        let left = makeTestDirectoryNode(id: "/root/area/left", name: "left", children: [leftFile])
        let right = makeTestDirectoryNode(id: "/root/area/right", name: "right", children: [rightFile])
        let area = makeTestDirectoryNode(id: "/root/area", name: "area", children: [left, right])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [sub, loose, area])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [sub, loose, area], sub.id: [big, small],
                area.id: [left, right], left.id: [leftFile], right.id: [rightFile],
            ]
        )

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "NeodiskKeyboardNavTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let defaultsSuiteName = "NeodiskKeyboardNavTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        let model = NeodiskViewModel(
            coordinator: ScanCoordinator(),
            snapshotCache: cache,
            pinnedFolderStore: PinnedFolderStore(defaults: defaults)
        )
        model.coordinator.replaceCurrentSnapshot(makeTestSnapshot(root: root, store: store))

        return Fixture(
            model: model, root: root, sub: sub, big: big, small: small, loose: loose,
            area: area, left: left, right: right, leftFile: leftFile, rightFile: rightFile,
            cacheDirectory: cacheDirectory, defaults: defaults, defaultsSuiteName: defaultsSuiteName
        )
    }

    @Test func testDrillIntoSelectedDirectoryReRootsAndSelectsLargestChild() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        model.select(fixture.sub.id)
        #expect(model.drillIntoSelection())

        // The map re-roots into the folder; selection lands on its biggest child.
        #expect(model.zoomRootID == fixture.sub.id)
        #expect(model.effectiveRootID == fixture.sub.id)
        #expect(model.selectedNodeID == fixture.big.id)
    }

    @Test func testDrillIntoSelectedFileReRootsToItsFolderKeepingSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // A file nested under `sub`: drilling zooms into `sub` but keeps the
        // file selected, so repeated ⌘↓ steps deeper from where you are.
        model.select(fixture.big.id)
        #expect(model.drillIntoSelection())
        #expect(model.zoomRootID == fixture.sub.id)
        #expect(model.selectedNodeID == fixture.big.id)
    }

    @Test func testDrillDoesNothingWithNoSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        model.select(nil)
        #expect(!model.drillIntoSelection())
        #expect(model.zoomRootID == nil)
    }

    @Test func testDrillIntoTopLevelFileIsRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // `loose.txt` sits directly under the scan root, which is already the
        // visible root — there is nowhere deeper to go.
        model.select(fixture.loose.id)
        #expect(!model.drillIntoSelection())
        #expect(model.zoomRootID == nil)
    }

    @Test func testBreadcrumbReRootDrillsOutToAncestorKeepingSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // Drilled into `sub` with a file selected; clicking the scan-root
        // crumb drills back out to it without disturbing the selection.
        model.zoomRootID = fixture.sub.id
        model.select(fixture.big.id)
        #expect(model.reRoot(to: fixture.root.id))
        #expect(model.zoomRootID == nil)
        #expect(model.selectedNodeID == fixture.big.id)
    }

    @Test func testBreadcrumbReRootNeverDrillsIn() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // At the full map, `sub` is below the root: clicking it must NOT
        // re-root (drilling in is keyboard-only). The current-root crumb is
        // likewise a no-op.
        #expect(!model.reRoot(to: fixture.sub.id))
        #expect(model.zoomRootID == nil)

        model.zoomRootID = fixture.sub.id
        #expect(!model.reRoot(to: fixture.sub.id))     // already the root
        #expect(model.zoomRootID == fixture.sub.id)
        #expect(!model.reRoot(to: fixture.big.id))     // a file, and below root
        #expect(model.zoomRootID == fixture.sub.id)
    }

    @Test func testSelectingOutsideDrillWidensToCommonAncestor() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // Drilled into area/left; selecting a file over in area/right widens
        // the map OUT only as far as `area`, their lowest common ancestor.
        model.zoomRootID = fixture.left.id
        model.select(fixture.rightFile.id)
        #expect(model.zoomRootID == fixture.area.id)
        #expect(model.selectedNodeID == fixture.rightFile.id)
    }

    @Test func testSelectingFarOutsideWidensToFullMap() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // Drilled into area/left; selecting something under `sub` shares only
        // the scan root, so the map widens all the way out.
        model.zoomRootID = fixture.left.id
        model.select(fixture.big.id)
        #expect(model.zoomRootID == nil)
        #expect(model.selectedNodeID == fixture.big.id)
    }

    @Test func testSelectingInsideDrillDoesNotWiden() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // A selection already inside the drilled subtree leaves the root put.
        model.zoomRootID = fixture.area.id
        model.select(fixture.leftFile.id)
        #expect(model.zoomRootID == fixture.area.id)

        // And at the full map, selecting anything never changes the root.
        model.zoomRootID = nil
        model.select(fixture.rightFile.id)
        #expect(model.zoomRootID == nil)
    }

    @Test func testDirectSelectionAssignmentWidensLikeTheOutline() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        // The outline and search set selectedNodeID directly, bypassing
        // select(); the widen must still happen (it lives in the didSet).
        model.zoomRootID = fixture.left.id
        model.selectedNodeID = fixture.rightFile.id
        #expect(model.zoomRootID == fixture.area.id)
    }

    @Test func testDrillOutReRootsUpThenRejectsAtRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        model.zoomRootID = fixture.sub.id
        #expect(model.drillOut())
        #expect(model.zoomRootID == nil)          // parent of `sub` is the scan root
        #expect(!model.drillOut())                // already at the root
    }
}
