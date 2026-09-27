//
//  TreemapNavCacheTests.swift
//  Neodisk
//
//  The per-scene navigation cache must be a pure optimization: arrow-key
//  targets from the precomputed candidates match the old refilter-every-
//  press scan over random scenes, and the controller's memoized selection
//  rect always equals a fresh `rect(forNodeID:)` for the scene on display.
//

import CoreGraphics
import Foundation
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskUI

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

/// The arrow-key resolution before the cache, verbatim over the cells:
/// the selected ID, or nil for a beep / no-op.
private func referenceMove(
    cells: [TreemapCell],
    selectionRect: CGRect?,
    selectedNodeID: String?,
    direction: TreemapKeyboardNav.Direction
) -> String? {
    let tiles = cells.filter {
        !$0.isFreeSpace && !$0.isHiddenSpace && $0.aggregate == nil && !$0.isContainer
    }
    guard !tiles.isEmpty else { return nil }
    guard let from = selectionRect.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
        return tiles.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })?.nodeID
    }
    var best: (nodeID: String, score: CGFloat)?
    for tile in tiles where tile.nodeID != selectedNodeID {
        let to = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        let dx = to.x - from.x, dy = to.y - from.y
        let primary: CGFloat
        let perpendicular: CGFloat
        switch direction {
        case .left: guard dx < -0.5 else { continue }; primary = -dx; perpendicular = abs(dy)
        case .right: guard dx > 0.5 else { continue }; primary = dx; perpendicular = abs(dy)
        case .up: guard dy < -0.5 else { continue }; primary = -dy; perpendicular = abs(dx)
        case .down: guard dy > 0.5 else { continue }; primary = dy; perpendicular = abs(dx)
        }
        let score = primary + 2 * perpendicular
        if best == nil || score < best!.score { best = (tile.nodeID, score) }
    }
    return best?.nodeID
}

/// The cached path, as the controller composes it.
private func cachedMove(
    candidates: [TreemapKeyboardNav.Candidate],
    selectionRect: CGRect?,
    selectedNodeID: String?,
    direction: TreemapKeyboardNav.Direction
) -> String? {
    guard !candidates.isEmpty else { return nil }
    guard let from = selectionRect.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
        return TreemapKeyboardNav.largest(in: candidates)
    }
    return TreemapKeyboardNav.target(
        from: from, direction: direction, excluding: selectedNodeID, in: candidates
    )
}

@Suite struct TreemapNavCacheTests {
    @Test func cachedNavigationMatchesRefilterOverRandomScenes() {
        var rng = SeededTestGenerator(seed: 0x7E3A)
        let directions: [TreemapKeyboardNav.Direction] = [.up, .down, .left, .right]
        for round in 0..<40 {
            let store = makeRandomStore(using: &rng)
            let size = CGSize(
                width: CGFloat(Int.random(in: 60...900, using: &rng)),
                height: CGFloat(Int.random(in: 60...700, using: &rng))
            )
            let style: TreemapStyle = Bool.random(using: &rng) ? .flat : .cushion
            // Cushion scenes also run zoomed and panned, pruning to the
            // render bounds.
            let viewport = style == .cushion && Bool.random(using: &rng)
                ? TreemapViewport(
                    scale: CGFloat.random(in: 1...6, using: &rng),
                    origin: .zero
                ).panned(
                    by: CGSize(
                        width: CGFloat.random(in: -2_000...2_000, using: &rng),
                        height: CGFloat.random(in: -2_000...2_000, using: &rng)
                    ),
                    viewSize: size
                )
                : .identity
            let scene = TreemapScene.build(
                store: store, rootID: store.rootID, style: style, size: size,
                catalog: .empty, viewport: viewport,
                freeSpaceBytes: Bool.random(using: &rng) ? store.root.allocatedSize / 3 : nil
            )
            let candidates = TreemapKeyboardNav.candidates(in: scene.cells)

            // No selection, then a handful of random selections: rendered
            // tiles, containers, merged nodes, and nodes pruned off-screen.
            let nodeIDs = store.allNodes.map(\.id)
            var selections: [String?] = [nil]
            for _ in 0..<12 { selections.append(nodeIDs.randomElement(using: &rng)) }
            for selectedNodeID in selections {
                let selectionRect = selectedNodeID.flatMap { scene.rect(forNodeID: $0, in: store) }
                for direction in directions {
                    let expected = referenceMove(
                        cells: scene.cells, selectionRect: selectionRect,
                        selectedNodeID: selectedNodeID, direction: direction
                    )
                    let actual = cachedMove(
                        candidates: candidates, selectionRect: selectionRect,
                        selectedNodeID: selectedNodeID, direction: direction
                    )
                    #expect(actual == expected, "round \(round) \(style) \(direction) from \(selectedNodeID ?? "nil")")
                }
            }
        }
    }

    /// The memoized selection rect is keyed by selection and dropped with
    /// the scene: after every selection change and every re-render (new
    /// size, new style) it equals a fresh layout of the scene on display.
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

    /// Opt-in (`NEODISK_TREEMAP_NAV_BENCH=1`): 1,000 arrow presses over a
    /// large scene, old path (refilter every cell, re-layout the selection
    /// path for the origin and again for the display refresh) against the
    /// cached one (precomputed candidates, memoized selection rect), plus
    /// the per-tick selection-rect cost a gesture or resize pays.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEODISK_TREEMAP_NAV_BENCH"] != nil))
    func benchArrowNavigation() {
        var childrenByID: [String: [FileNodeRecord]] = [:]
        var rng = SeededTestGenerator(seed: 9)
        func makeDirectory(id: String, depth: Int) -> FileNodeRecord {
            var children: [FileNodeRecord] = []
            let fanout = depth == 0 ? 40 : 12
            for index in 0..<fanout {
                let childID = "\(id)/n\(index)"
                if depth < 3, index % 3 == 0 {
                    children.append(makeDirectory(id: childID, depth: depth + 1))
                } else {
                    children.append(makeTestFileNode(
                        id: childID, name: "n\(index)",
                        size: Int64.random(in: 1_000...10_000_000, using: &rng)
                    ))
                }
            }
            let sorted = FileTreeStore.sortedChildren(children)
            childrenByID[id] = sorted
            return makeTestDirectoryNode(id: id, name: "d", children: sorted)
        }
        let store = FileTreeStore(root: makeDirectory(id: "/r", depth: 0), childrenByID: childrenByID)
        let scene = TreemapScene.build(
            store: store, rootID: store.rootID, style: .cushion,
            size: CGSize(width: 1_600, height: 1_000), catalog: .empty
        )
        let directions: [TreemapKeyboardNav.Direction] = [.right, .down, .left, .up, .right, .right, .down]
        let clock = ContinuousClock()
        let presses = 1_000

        var oldSelection: String?
        let oldTime = clock.measure {
            for press in 0..<presses {
                let rect = oldSelection.flatMap { scene.rect(forNodeID: $0, in: store) }
                oldSelection = referenceMove(
                    cells: scene.cells, selectionRect: rect, selectedNodeID: oldSelection,
                    direction: directions[press % directions.count]
                ) ?? oldSelection
                _ = oldSelection.flatMap { scene.rect(forNodeID: $0, in: store) } // display refresh
            }
        }
        var newSelection: String?
        var memo: (nodeID: String, rect: CGRect?)?
        func memoRect(_ id: String?) -> CGRect? {
            guard let id else { return nil }
            if let memo, memo.nodeID == id { return memo.rect }
            let rect = scene.rect(forNodeID: id, in: store)
            memo = (id, rect)
            return rect
        }
        let newTime = clock.measure {
            let candidates = TreemapKeyboardNav.candidates(in: scene.cells)
            for press in 0..<presses {
                newSelection = cachedMove(
                    candidates: candidates, selectionRect: memoRect(newSelection),
                    selectedNodeID: newSelection, direction: directions[press % directions.count]
                ) ?? newSelection
                _ = memoRect(newSelection) // display refresh
            }
        }
        #expect(newSelection == oldSelection)

        let ticks = 1_000
        let selected = store.allNodes.last!.id
        let oldTicks = clock.measure {
            for _ in 0..<ticks { _ = scene.rect(forNodeID: selected, in: store) }
        }
        memo = nil
        let newTicks = clock.measure {
            for _ in 0..<ticks { _ = memoRect(selected) }
        }
        print("NAVBENCH \(scene.cells.count) cells: \(presses) presses \(oldTime) → \(newTime); \(ticks) refresh ticks \(oldTicks) → \(newTicks)")
    }
}
