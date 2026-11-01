#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskAppModel

/// → deeper, ← shallower, ↑↓ siblings in display order; only drawn items are reachable.
struct TreeKeyboardNavTests {
    /// root: docs 110 (big.pdf 100, mid.pdf 10, small.pdf 5), media 60 (movie.mp4 60), notes 20, tiny.txt 1.
    private struct Fixture {
        let store: FileTreeStore
        var rendered: Set<String>

        init() {
            let big = makeTestFileNode(id: "/root/docs/big.pdf", name: "big.pdf", size: 100)
            let mid = makeTestFileNode(id: "/root/docs/mid.pdf", name: "mid.pdf", size: 10)
            let small = makeTestFileNode(id: "/root/docs/small.pdf", name: "small.pdf", size: 5)
            let docs = makeTestDirectoryNode(id: "/root/docs", name: "docs", children: [big, mid, small])
            let movie = makeTestFileNode(id: "/root/media/movie.mp4", name: "movie.mp4", size: 60)
            let media = makeTestDirectoryNode(id: "/root/media", name: "media", children: [movie])
            let notes = makeTestFileNode(id: "/root/notes", name: "notes", size: 20)
            let tiny = makeTestFileNode(id: "/root/tiny.txt", name: "tiny.txt", size: 1)
            let root = makeTestDirectoryNode(id: "/root", name: "root", children: [docs, media, notes, tiny])
            store = FileTreeStore(root: root, childrenByID: [
                root.id: [docs, media, notes, tiny], docs.id: [big, mid, small], media.id: [movie],
            ])
            // tiny.txt and small.pdf pooled into "smaller items".
            rendered = ["/root", "/root/docs", "/root/docs/big.pdf", "/root/docs/mid.pdf",
                        "/root/media", "/root/media/movie.mp4", "/root/notes"]
        }

        func target(
            _ from: String?, _ move: TreeKeyboardNav.Move, root: String = "/root"
        ) -> TreeKeyboardNav.Target? {
            TreeKeyboardNav.target(
                from: from, move: move, rootID: root, store: store, isRendered: rendered.contains
            )
        }
    }

    private let moves: [TreeKeyboardNav.Move] = [.child, .parent, .previous, .next]

    @Test func noSelectionPicksTheLargestTopLevelItem() {
        let fixture = Fixture()
        for move in moves {
            #expect(fixture.target(nil, move) == .select("/root/docs"))
            // The map's root and items outside it count as no selection.
            #expect(fixture.target("/root", move) == .select("/root/docs"))
            #expect(fixture.target("/nowhere", move) == .select("/root/docs"))
            #expect(fixture.target("/root/media", move, root: "/root/docs") == .select("/root/docs/big.pdf"))
        }
    }

    @Test func undrawnSelectionComesBackToItsDrawnAncestor() {
        let fixture = Fixture()
        for move in moves {
            #expect(fixture.target("/root/docs/small.pdf", move) == .select("/root/docs"))
            // Pooled at the top level: nothing drawn between it and the root.
            #expect(fixture.target("/root/tiny.txt", move) == .select("/root/docs"))
        }
    }

    @Test func rightSelectsTheLargestDrawnChild() {
        var fixture = Fixture()
        #expect(fixture.target("/root/docs", .child) == .select("/root/docs/big.pdf"))
        #expect(fixture.target("/root/media", .child) == .select("/root/media/movie.mp4"))
        #expect(fixture.target("/root/docs/big.pdf", .child) == nil)
        // A folder drawn whole (beyond depth) has no reachable children.
        fixture.rendered.subtract(["/root/media/movie.mp4"])
        #expect(fixture.target("/root/media", .child) == nil)
        fixture.rendered.remove("/root/docs/big.pdf")
        #expect(fixture.target("/root/docs", .child) == .select("/root/docs/mid.pdf"))
    }

    @Test func leftSelectsTheParentAndDrillsOutAtTheTop() {
        let fixture = Fixture()
        #expect(fixture.target("/root/docs/mid.pdf", .parent) == .select("/root/docs"))
        // At the scan root there is nothing shallower.
        #expect(fixture.target("/root/docs", .parent) == nil)
        // Drilled into docs: out one level, selecting docs.
        #expect(fixture.target("/root/docs/big.pdf", .parent, root: "/root/docs") == .drillOut(selecting: "/root/docs"))
    }

    @Test func upAndDownFollowDisplayOrderAndStopAtTheEnds() {
        var fixture = Fixture()
        #expect(fixture.target("/root/docs", .next) == .select("/root/media"))
        #expect(fixture.target("/root/media", .next) == .select("/root/notes"))
        #expect(fixture.target("/root/notes", .previous) == .select("/root/media"))
        #expect(fixture.target("/root/docs", .previous) == nil)
        // tiny.txt is pooled: notes is the last drawn sibling.
        #expect(fixture.target("/root/notes", .next) == nil)
        #expect(fixture.target("/root/docs/big.pdf", .next) == .select("/root/docs/mid.pdf"))
        #expect(fixture.target("/root/docs/mid.pdf", .next) == nil)
        // An undrawn sibling in the middle is skipped.
        fixture.rendered.remove("/root/media")
        fixture.rendered.remove("/root/media/movie.mp4")
        #expect(fixture.target("/root/docs", .next) == .select("/root/notes"))
    }

    // MARK: - What a treemap drew

    @Test func cushionSceneDrawsLeavesAndTheirFolders() {
        let fixture = Fixture()
        let scene = TreemapScene.build(
            store: fixture.store, rootID: "/root", size: CGSize(width: 400, height: 300), catalog: .empty,
            freeSpaceBytes: 50
        )
        let rendered = TreeKeyboardNav.renderedIDs(in: scene.cells, store: fixture.store)
        #expect(rendered.isSuperset(of: ["/root", "/root/docs", "/root/docs/big.pdf", "/root/media/movie.mp4"]))
        #expect(!rendered.contains(where: { $0.hasSuffix("__free-space__") }))
        // Every drawn cell's node is reachable, and nothing else is invented.
        let nodeIDs = Set(fixture.store.allNodes.map(\.id))
        #expect(rendered.isSubset(of: nodeIDs))
    }

    @Test func pooledItemsAreNotDrawn() {
        // One big file and many slivers: the slivers merge into "smaller items".
        let big = makeTestFileNode(id: "/r/big", name: "big", size: 1_000_000)
        let slivers = (0..<40).map { makeTestFileNode(id: "/r/s\($0)", name: "s\($0)", size: 1_000) }
        let children = FileTreeStore.sortedChildren([big] + slivers)
        let root = makeTestDirectoryNode(id: "/r", name: "r", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        let scene = TreemapScene.build(store: store, rootID: "/r", size: CGSize(width: 200, height: 150), catalog: .empty)
        #expect(scene.cells.contains { $0.aggregate != nil })
        let rendered = TreeKeyboardNav.renderedIDs(in: scene.cells, store: store)
        #expect(rendered.contains("/r/big"))
        #expect(!slivers.contains { rendered.contains($0.id) })
        let target = TreeKeyboardNav.target(
            from: "/r/big", move: .next, rootID: "/r", store: store, isRendered: rendered.contains
        )
        #expect(target == nil)
    }

    /// Over random scenes (both styles, zoomed, with free space): every move lands on a drawn item under the
    /// root, in the relation its key promises.
    @Test func movesStayOnDrawnItemsOverRandomScenes() {
        var rng = SeededTestGenerator(seed: 0x7E3A)
        for round in 0..<40 {
            let store = makeRandomStore(using: &rng)
            let size = CGSize(
                width: CGFloat(Int.random(in: 60...900, using: &rng)),
                height: CGFloat(Int.random(in: 60...700, using: &rng))
            )
            let style: TreemapStyle = Bool.random(using: &rng) ? .flat : .cushion
            let viewport = style == .cushion && Bool.random(using: &rng)
                ? TreemapViewport(scale: CGFloat.random(in: 1...6, using: &rng), origin: .zero).panned(
                    by: CGSize(
                        width: CGFloat.random(in: -2_000...2_000, using: &rng),
                        height: CGFloat.random(in: -2_000...2_000, using: &rng)
                    ),
                    viewSize: size
                )
                : .identity
            let scene = TreemapScene.build(
                store: store, rootID: store.rootID, style: style, size: size, catalog: .empty, viewport: viewport,
                freeSpaceBytes: Bool.random(using: &rng) ? store.root.allocatedSize / 3 : nil
            )
            let rendered = TreeKeyboardNav.renderedIDs(in: scene.cells, store: store)
            let nodeIDs = store.allNodes.map(\.id)
            var selections: [String?] = [nil]
            for _ in 0..<12 { selections.append(nodeIDs.randomElement(using: &rng)) }
            for selected in selections {
                for move in moves {
                    let label = "round \(round) \(style) \(move) from \(selected ?? "nil")"
                    guard let target = TreeKeyboardNav.target(
                        from: selected, move: move, rootID: store.rootID, store: store, isRendered: rendered.contains
                    ) else { continue }
                    guard case .select(let id) = target else {
                        Issue.record("drill out at the scan root: \(label)")
                        continue
                    }
                    #expect(rendered.contains(id) && id != store.rootID, "\(label)")
                    guard let selected, selected != store.rootID, rendered.contains(selected) else { continue }
                    let parent = store.parent(of: selected)?.id
                    switch move {
                    case .child: #expect(store.parent(of: id)?.id == selected, "\(label)")
                    case .parent: #expect(id == parent, "\(label)")
                    case .previous, .next:
                        #expect(store.parent(of: id)?.id == parent, "\(label)")
                        let order = store.children(of: parent).map(\.id)
                        let forward = order.firstIndex(of: id)! > order.firstIndex(of: selected)!
                        #expect(forward == (move == .next), "\(label)")
                    }
                }
            }
        }
    }
}

/// Nested folders with a heavy-tailed size mix, so scenes carry aggregates, flat containers and undivided folders.
private func makeRandomStore(using rng: inout SeededTestGenerator) -> FileTreeStore {
    var childrenByID: [String: [FileNodeRecord]] = [:]
    func makeDirectory(id: String, depth: Int) -> FileNodeRecord {
        var children: [FileNodeRecord] = []
        for index in 0..<Int.random(in: 0...9, using: &rng) {
            let childID = "\(id)/n\(index)"
            if depth < 4, Int.random(in: 0..<3, using: &rng) == 0 {
                children.append(makeDirectory(id: childID, depth: depth + 1))
            } else {
                let size: Int64 = switch Int.random(in: 0..<4, using: &rng) {
                case 0: Int64.random(in: 1...50, using: &rng)
                case 1: Int64.random(in: 50...5_000, using: &rng)
                case 2: Int64.random(in: 5_000...500_000, using: &rng)
                default: 1_000 // equal sizes exercise ordering ties
                }
                children.append(makeTestFileNode(id: childID, name: "n\(index).bin", size: size))
            }
        }
        let sorted = FileTreeStore.sortedChildren(children)
        childrenByID[id] = sorted
        return makeTestDirectoryNode(id: id, name: String(id.split(separator: "/").last ?? "root"), children: sorted)
    }
    let root = makeDirectory(id: "/r", depth: 0)
    return FileTreeStore(root: root, childrenByID: childrenByID)
}
