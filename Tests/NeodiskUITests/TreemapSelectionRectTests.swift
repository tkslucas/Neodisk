// The selection-rect memo must be a pure optimization: the same rects as a fresh layout.

import CoreGraphics
import Foundation
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskUI
@testable import NeodiskAppModel

/// A random tree: nested folders with a heavy-tailed size mix, so scenes
/// carry aggregates, flat containers, and undivided folders.
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
        return makeTestDirectoryNode(
            id: id, name: String(id.split(separator: "/").last ?? "root"), children: sorted
        )
    }
    let root = makeDirectory(id: "/r", depth: 0)
    return FileTreeStore(root: root, childrenByID: childrenByID)
}

@Suite struct TreemapSelectionRectTests {
    /// After every selection change and re-render it must equal a fresh layout of the scene on display.
    @MainActor
    @Test func controllerSelectionRectTracksSelectionAndScene() async throws {
        var rng = SeededTestGenerator(seed: 0xC0FFEE)
        let store = makeRandomStore(using: &rng)
        let snapshot = makeTestSnapshot(root: store.root, store: store)
        let controller = TreemapController()
        let nodeIDs = store.allNodes.map(\.id)

        func assertMatchesFreshLayout() throws {
            let scene = try #require(controller.scene)
            for _ in 0..<8 {
                let id = nodeIDs.randomElement(using: &rng)!
                controller.setSelectedNode(id)
                let expected = scene.rect(forNodeID: id, in: store)
                #expect(controller.selectionRect == expected)
                // A repeat read serves the memo; it must not drift.
                #expect(controller.selectionRect == expected)
            }
            controller.setSelectedNode(nil)
            #expect(controller.selectionRect == nil)
        }

        controller.setInputs(
            snapshot: snapshot, rootID: store.rootID, catalog: .empty,
            style: .cushion, expandedAggregateIDs: []
        )
        controller.setViewSize(CGSize(width: 640, height: 480))
        try await waitUntil("first scene") { controller.scene?.size == CGSize(width: 640, height: 480) }
        try assertMatchesFreshLayout()

        // Keep a selection across a re-render: the memo from the old scene
        // must not survive the new one.
        let kept = nodeIDs.last!
        controller.setSelectedNode(kept)
        _ = controller.selectionRect
        controller.setInputs(
            snapshot: snapshot, rootID: store.rootID, catalog: .empty,
            style: .flat, expandedAggregateIDs: []
        )
        try await waitUntil("flat scene") { controller.scene?.style == .flat }
        let flatScene = try #require(controller.scene)
        #expect(controller.selectionRect == flatScene.rect(forNodeID: kept, in: store))
        try assertMatchesFreshLayout()
    }

    /// Several selected items: one ring each, matching a fresh layout; one item is exactly `selectionRect`.
    @MainActor
    @Test func controllerRingsEverySelectedItem() async throws {
        var rng = SeededTestGenerator(seed: 0xBEEF)
        let store = makeRandomStore(using: &rng)
        let snapshot = makeTestSnapshot(root: store.root, store: store)
        let controller = TreemapController()
        controller.setInputs(
            snapshot: snapshot, rootID: store.rootID, catalog: .empty,
            style: .cushion, expandedAggregateIDs: []
        )
        controller.setViewSize(CGSize(width: 640, height: 480))
        try await waitUntil("scene") { controller.scene?.size == CGSize(width: 640, height: 480) }
        let scene = try #require(controller.scene)
        let ids = Array(store.allNodes.map(\.id).shuffled(using: &rng).prefix(12))

        controller.setSelection(NodeSelection(ids))
        var expected: [CGRect] = []
        for rect in ids.compactMap({ scene.rect(forNodeID: $0, in: store) }) where !expected.contains(rect) {
            expected.append(rect)
        }
        #expect(controller.selectionRects == expected)
        #expect(controller.selectionRect == scene.rect(forNodeID: ids.last!, in: store))

        controller.setSelectedNode(ids[0])
        #expect(controller.selectionRects == [scene.rect(forNodeID: ids[0], in: store)].compactMap { $0 })
        controller.setSelection(NodeSelection())
        #expect(controller.selectionRects.isEmpty)
    }
}
