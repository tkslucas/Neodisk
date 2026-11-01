#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskAppModel

/// `rects(forNodeIDs:)` lays each folder out once; it must agree with `rect(forNodeID:)` node for node.
@Suite struct TreemapSceneBatchRectsTests {
    /// A big file, a folder of many small files (some merge into "smaller items"), a nested folder, and an empty one.
    private func makeStore() -> (FileTreeStore, [String]) {
        func file(_ id: String, _ size: Int64) -> FileNodeRecord {
            makeTestFileNode(id: id, name: String(id.split(separator: "/").last!), size: size)
        }
        let deep = (0..<6).map { file("/scan/sub/deep/d\($0).bin", Int64(5_000 + $0 * 700)) }
        let deepDir = makeTestDirectoryNode(
            id: "/scan/sub/deep", name: "deep", children: FileTreeStore.sortedChildren(deep)
        )
        let small = (0..<40).map { file("/scan/sub/s\($0).bin", Int64(300 + $0 * 37)) }
        let subChildren = FileTreeStore.sortedChildren([file("/scan/sub/big.bin", 400_000), deepDir] + small)
        let sub = makeTestDirectoryNode(id: "/scan/sub", name: "sub", children: subChildren)
        let empty = makeTestDirectoryNode(id: "/scan/empty", name: "empty", children: [])
        let rootChildren = FileTreeStore.sortedChildren(
            [file("/scan/a.mov", 900_000), file("/scan/b.jpg", 120_000), sub, empty]
        )
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: rootChildren)
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                "/scan": rootChildren,
                "/scan/sub": subChildren,
                "/scan/sub/deep": FileTreeStore.sortedChildren(deep),
            ]
        )
        let ids = ["/scan"] + rootChildren.map(\.id) + subChildren.map(\.id) + deep.map(\.id)
            + ["/elsewhere/missing"]
        return (store, ids)
    }

    @Test(arguments: [TreemapStyle.cushion, .flat], [false, true])
    func batchAgreesWithSingleLookups(style: TreemapStyle, exact: Bool) {
        let (store, ids) = makeStore()
        for viewport in [TreemapViewport.identity, TreemapViewport(scale: 3, origin: CGPoint(x: 120, y: 40))] {
            let scene = TreemapScene.build(
                store: store, rootID: "/scan", style: style,
                size: CGSize(width: 400, height: 300), catalog: .empty, viewport: viewport
            )
            let batch = scene.rects(forNodeIDs: ids, in: store, exact: exact)
            for id in ids {
                #expect(batch[id] == scene.rect(forNodeID: id, in: store, exact: exact), "\(style) \(id)")
            }
        }
    }

    @Test func drilledSceneLeavesOutNodesAboveItsRoot() {
        let (store, ids) = makeStore()
        let scene = TreemapScene.build(
            store: store, rootID: "/scan/sub", size: CGSize(width: 400, height: 300), catalog: .empty
        )
        let batch = scene.rects(forNodeIDs: ids, in: store)
        #expect(batch["/scan/a.mov"] == nil)
        #expect(batch["/scan"] == nil)
        #expect(batch["/scan/sub/big.bin"] != nil)
    }
}
