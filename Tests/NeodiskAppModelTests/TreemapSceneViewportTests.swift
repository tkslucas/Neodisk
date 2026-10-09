//
//  TreemapSceneViewportTests.swift
//  Neodisk
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskAppModel

@Suite struct TreemapSceneViewportTests {
    private let viewSize = CGSize(width: 800, height: 600)

    private func makeStore() -> FileTreeStore {
        let big = makeTestFileNode(id: "/root/big.bin", name: "big.bin", size: 900)
        let small = makeTestFileNode(id: "/root/small.bin", name: "small.bin", size: 100)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [big, small])
        return FileTreeStore(root: root, childrenByID: [root.id: [big, small]])
    }

    @Test func coversIsTrueForPansInsideOverscan() {
        let viewport = TreemapViewport(scale: 4, origin: CGPoint(x: 1000, y: 800))
        let scene = TreemapScene.build(
            store: makeStore(), rootID: "/root", size: viewSize,
            catalog: .empty, viewport: viewport
        )
        #expect(scene.covers(viewport, viewSize: viewSize))

        let smallPan = viewport.panned(by: CGSize(width: -50, height: -40), viewSize: viewSize)
        #expect(scene.covers(smallPan, viewSize: viewSize))

        let hugePan = viewport.panned(by: CGSize(width: -1000, height: 0), viewSize: viewSize)
        #expect(!scene.covers(hugePan, viewSize: viewSize))
    }

    @Test func coversIsFalseAcrossScaleOrSizeChanges() {
        let viewport = TreemapViewport(scale: 2, origin: CGPoint(x: 100, y: 100))
        let scene = TreemapScene.build(
            store: makeStore(), rootID: "/root", size: viewSize,
            catalog: .empty, viewport: viewport
        )
        #expect(!scene.covers(
            viewport.zoomed(by: 1.01, anchor: .zero, viewSize: viewSize),
            viewSize: viewSize
        ))
        #expect(!scene.covers(viewport, viewSize: CGSize(width: 801, height: 600)))
    }

    @Test func sceneForMissingRootIsEmptyNotCrashing() {
        let scene = TreemapScene.build(
            store: makeStore(), rootID: "/nonexistent", size: viewSize, catalog: .empty
        )
        #expect(scene.cells.isEmpty)
        #expect(scene.cell(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(scene.rect(forNodeID: "/root/big.bin", in: makeStore()) == nil)
    }

    @Test func sceneForZeroSizedTreeRendersRootOnly() {
        let empty = makeTestFileNode(id: "/root/zero.bin", name: "zero.bin", size: 0)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [empty])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [empty]])
        let scene = TreemapScene.build(
            store: store, rootID: "/root", size: viewSize, catalog: .empty
        )
        // The zero-sized child is filtered out; the root renders as one cell.
        #expect(scene.cells.count == 1)
        #expect(scene.cells.first?.nodeID == "/root")
    }
}
