#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SunburstCore
import Testing
import TreemapKit
import NeodiskKit
@testable import NeodiskAppModel

/// `NEODISK_TREEMAP_BENCH=<nodes>` (e.g. 500000): scene build, raster and hit-test timings over a seeded tree.
/// Run in release: `swift test -c release --filter TreemapBench`.
private func treemapBenchNodeCount() -> Int? {
    ProcessInfo.processInfo.environment["NEODISK_TREEMAP_BENCH"].flatMap(Int.init)
}

/// A heavy-tailed tree: folders fan out 2–40 wide, files take Pareto-ish sizes, so a few big
/// subtrees dominate like a real disk.
func makeBenchStore(nodeCount: Int, seed: UInt64 = 7) -> FileTreeStore {
    var rng = SeededTestGenerator(seed: seed)
    var childrenByID: [String: [FileNodeRecord]] = [:]
    var made = 0
    let extensions = ["mov", "jpg", "swift", "json", "zip", "txt", "png", "o", "dylib", "md"]

    func build(path: String, depth: Int) -> FileNodeRecord {
        let fanout = Int.random(in: 2...40, using: &rng)
        var children: [FileNodeRecord] = []
        for index in 0..<fanout where made < nodeCount {
            made += 1
            let goDeeper = depth < 9 && Double.random(in: 0..<1, using: &rng) < 0.18
            if goDeeper {
                children.append(build(path: "\(path)/d\(index)", depth: depth + 1))
            } else {
                let u = Double.random(in: 0.0001..<1, using: &rng)
                let size = Int64(4096 * pow(u, -1.4))
                let name = "f\(index).\(extensions[index % extensions.count])"
                children.append(makeTestFileNode(id: "\(path)/\(name)", name: name, size: size))
            }
        }
        childrenByID[path] = children
        return makeTestDirectoryNode(id: path, name: (path as NSString).lastPathComponent, children: children)
    }

    var topLevel: [FileNodeRecord] = []
    var index = 0
    while made < nodeCount {
        topLevel.append(build(path: "/bench/t\(index)", depth: 1))
        index += 1
    }
    childrenByID["/bench"] = topLevel
    let root = makeTestDirectoryNode(id: "/bench", name: "bench", children: topLevel)
    return FileTreeStore(root: root, childrenByID: childrenByID)
}

@Suite(.serialized) struct TreemapBenchTests {
    private static func best(_ runs: Int = 5, _ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<runs).map { _ in clock.measure(body) }.min()!
    }

    @Test(.enabled(if: treemapBenchNodeCount() != nil))
    func benchTreemap() throws {
        let count = try #require(treemapBenchNodeCount())
        let store = makeBenchStore(nodeCount: count)
        let catalog = FileKindCatalog.build(from: store, mode: .categories)
        let size = CGSize(width: 1600, height: 1000)
        print("TREEMAPBENCH nodes=\(store.nodeCount)")

        for style in [TreemapStyle.cushion, .flat] {
            for (label, viewport) in [
                ("1x", TreemapViewport.identity),
                ("8x", TreemapViewport(scale: 8, origin: CGPoint(x: 4000, y: 2500))),
            ] {
                var scene: TreemapScene?
                let build = Self.best {
                    scene = TreemapScene.build(
                        store: store, rootID: store.rootID, style: style, size: size,
                        catalog: catalog, viewport: viewport
                    )
                }
                let built = try #require(scene)
                var pixels: [UInt8] = []
                let raster = Self.best {
                    pixels = (style == .flat
                        ? FlatTreemapRenderer.rasterizeRGBA(cells: built.cells, bounds: built.renderBounds, scale: 2)
                        : CushionTreemapRenderer.rasterizeRGBA(cells: built.cells, bounds: built.renderBounds, scale: 2)
                    )?.pixels ?? []
                }
                // FNV-1a over the raster, so a perf change can show it left every pixel alone.
                let checksum = pixels.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
                var rng = SeededTestGenerator(seed: 1)
                let points = (0..<100_000).map { _ in
                    CGPoint(x: Double.random(in: 0..<size.width, using: &rng), y: Double.random(in: 0..<size.height, using: &rng))
                }
                var hits = 0
                let hitTest = Self.best(3) {
                    hits = 0
                    for point in points where built.cell(at: point) != nil { hits += 1 }
                }
                print("TREEMAPBENCH \(style) \(label): cells=\(built.cells.count) labels=\(built.labels.count) build=\(build) raster@2x=\(raster) hit100k=\(hitTest) hits=\(hits) raster=\(String(checksum, radix: 16))")
            }
        }
    }
}
