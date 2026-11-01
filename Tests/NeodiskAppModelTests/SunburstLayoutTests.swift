// SunburstCore's layout against a minimal stdlib tree: angles, rings, aggregation, synthetic arcs and the
// scan-root-anchored color coordinate. Runs on every platform (the macOS geometry suite covers styling).

import SunburstCore
import Testing

private struct LayoutNode: SunburstNode {
    let id: String
    var name: String { id }
    var isDirectory = false
    var isPackage = false
    var allocatedSize: Int64 = 0
    var descendantFileCount = 1
    var cloudOnlyLogicalSize: Int64 = 0
    var isDataless = false

    func displayWeight(includingCloudOnly: Bool) -> Int64 {
        allocatedSize + (includingCloudOnly ? cloudOnlyLogicalSize : 0)
    }
}

/// Only the required members, so the protocol's default cloud-only behavior is what runs.
private struct PlainNode: SunburstNode {
    let id: String
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let allocatedSize: Int64
    let descendantFileCount: Int
}

private struct LayoutCancelled: Error {}

/// Parent links are explicit so a test can build an orphan whose path its parent doesn't list.
private struct LayoutTree: SunburstTreeReading {
    let rootID: String
    var nodes: [String: LayoutNode] = [:]
    var childIDs: [String: [String]] = [:]
    var parentIDs: [String: String] = [:]

    init(root: LayoutNode) {
        rootID = root.id
        nodes[root.id] = root
    }

    mutating func add(_ node: LayoutNode, under parentID: String, listed: Bool = true) {
        nodes[node.id] = node
        parentIDs[node.id] = parentID
        if listed {
            childIDs[parentID, default: []].append(node.id)
        }
    }

    func node(id: String?) -> LayoutNode? {
        id.flatMap { nodes[$0] }
    }

    func children(of id: String?) -> [LayoutNode] {
        (id.flatMap { childIDs[$0] } ?? []).compactMap { nodes[$0] }
    }

    func children(of id: String?, cancellationCheck: () throws -> Void) throws -> [LayoutNode] {
        try cancellationCheck()
        return children(of: id)
    }

    func parent(of id: String?) -> LayoutNode? {
        id.flatMap { parentIDs[$0] }.flatMap { nodes[$0] }
    }

    func path(to id: String?) -> [LayoutNode] {
        var chain: [LayoutNode] = []
        var cursor = id
        while let current = cursor, let node = nodes[current] {
            chain.append(node)
            cursor = parentIDs[current]
        }
        return chain.reversed()
    }

    func containsChildren(id: String?) -> Bool {
        !children(of: id).isEmpty
    }

    func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        path(to: descendantID).dropLast().contains { $0.id == ancestorID }
    }
}

private func approx(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) < tolerance
}

private func file(_ id: String, _ size: Int64) -> LayoutNode {
    LayoutNode(id: id, allocatedSize: size)
}

private func folder(_ id: String, _ size: Int64, files: Int = 1) -> LayoutNode {
    LayoutNode(id: id, isDirectory: true, allocatedSize: size, descendantFileCount: files)
}

/// root(8) → dir(6) → x(4), y(2); root → f(2).
private func nestedTree() -> LayoutTree {
    var tree = LayoutTree(root: folder("root", 8, files: 3))
    tree.add(folder("dir", 6, files: 2), under: "root")
    tree.add(file("f", 2), under: "root")
    tree.add(file("x", 4), under: "dir")
    tree.add(file("y", 2), under: "dir")
    return tree
}

private func layout(
    _ tree: LayoutTree,
    rootID: String? = nil,
    depthLimit: Int = 4,
    freeSpaceBytes: Int64? = nil,
    hiddenSpaceBytes: Int64? = nil,
    expandedAggregateIDs: Set<String> = [],
    includeCloudOnly: Bool = false
) throws -> [SunburstSegment] {
    try SunburstLayout.segments(
        in: tree,
        rootID: rootID ?? tree.rootID,
        depthLimit: depthLimit,
        freeSpaceBytes: freeSpaceBytes,
        hiddenSpaceBytes: hiddenSpaceBytes,
        expandedAggregateIDs: expandedAggregateIDs,
        includeCloudOnly: includeCloudOnly,
        freeSpaceLabel: "Free",
        hiddenSpaceLabel: "Hidden",
        cancellationCheck: {}
    )
}

@Suite struct SunburstLayoutTests {
    @Test func zeroDepthOrUnknownRootLaysOutNothing() throws {
        let tree = nestedTree()
        #expect(try layout(tree, depthLimit: 0).isEmpty)
        #expect(try layout(tree, depthLimit: -3).isEmpty)
        #expect(try layout(tree, rootID: "missing").isEmpty)
    }

    @Test func childlessRootFillsTheWholeTopRingWithItself() throws {
        let tree = LayoutTree(root: file("solo", 10))
        let segments = try layout(tree)
        #expect(segments.count == 1)
        let solo = try #require(segments.first)
        #expect(solo.nodeID == "solo")
        #expect(solo.startAngle == 0)
        #expect(approx(solo.endAngle, .pi * 2))
        #expect(solo.colorToken.role == .file)
        #expect(solo.depth == 0)
    }

    @Test func nestedRingsSplitTheirParentsArcBySize() throws {
        let segments = try layout(nestedTree())
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        #expect(segments.map(\.id) == ["dir", "x", "y", "f"])

        let dir = try #require(byID["dir"])
        let f = try #require(byID["f"])
        let x = try #require(byID["x"])
        let y = try #require(byID["y"])
        #expect(approx(dir.startAngle, 0) && approx(dir.endAngle, .pi * 1.5))
        #expect(approx(f.startAngle, .pi * 1.5) && approx(f.endAngle, .pi * 2))
        #expect(approx(x.startAngle, 0) && approx(x.endAngle, .pi))
        #expect(approx(y.startAngle, .pi) && approx(y.endAngle, .pi * 1.5))

        // Both rings cover enough of the circle to stay, so the chart is banded for two of the four allowed.
        let metrics = SunburstRingMetrics(depthLimit: 2)
        #expect(dir.depth == 0 && x.depth == 1)
        #expect(approx(dir.innerRadius, metrics.innerRadius(depth: 0)))
        #expect(approx(dir.outerRadius, metrics.drawnOuterRadius(depth: 0)))
        #expect(approx(x.innerRadius, metrics.innerRadius(depth: 1)))
        #expect(approx(x.outerRadius, metrics.drawnOuterRadius(depth: 1)))

        #expect(dir.colorToken.role == .normal)
        #expect(f.colorToken.role == .file)
        #expect(dir.totalSize == 6 && x.totalSize == 4)
        #expect(!dir.isAggregate && dir.parentFolderID == nil && dir.itemCount == 0)
    }

    @Test func depthLimitStopsTheRecursion() throws {
        let segments = try layout(nestedTree(), depthLimit: 1)
        #expect(segments.map(\.id) == ["dir", "f"])
        #expect(segments.allSatisfy { $0.depth == 0 })
    }

    @Test func colorTokensCarryScanRootIntervalMidpoints() throws {
        let segments = try layout(nestedTree())
        let tokens = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.colorToken) })
        // dir spans [0, 0.75) of the root interval, f [0.75, 1); x and y split dir's 4:2.
        #expect(approx(tokens["dir"]?.midpoint ?? -1, 0.375))
        #expect(approx(tokens["f"]?.midpoint ?? -1, 0.875))
        #expect(approx(tokens["x"]?.midpoint ?? -1, 0.25))
        #expect(approx(tokens["y"]?.midpoint ?? -1, 0.625))
        #expect(tokens["dir"]?.depth == 1)
        #expect(tokens["x"]?.depth == 2)
    }

    @Test func drillingInKeepsTheScanRootColors() throws {
        let tree = nestedTree()
        let full = try layout(tree)
        let drilled = try layout(tree, rootID: "dir")
        #expect(drilled.map(\.id) == ["x", "y"])
        // The drilled layout takes the whole circle on the top ring…
        #expect(approx(drilled[0].startAngle, 0) && approx(drilled[1].endAngle, .pi * 2))
        #expect(drilled.allSatisfy { $0.depth == 0 })
        // …but each node keeps the color token it had in the scan-root layout.
        for segment in drilled {
            let original = try #require(full.first { $0.id == segment.id })
            #expect(segment.colorToken == original.colorToken)
        }
    }

    @Test func rootOwnBytesLeaveATrailingGap() throws {
        var tree = LayoutTree(root: folder("root", 10))
        tree.add(file("a", 4), under: "root")
        tree.add(file("b", 4), under: "root")
        let segments = try layout(tree)
        #expect(approx(segments[1].endAngle, .pi * 2 * 0.8))
    }

    @Test func zeroByteChildrenCountOneUnitAndNeverOverflow() throws {
        var tree = LayoutTree(root: folder("root", 0))
        tree.add(file("a", 0), under: "root")
        tree.add(file("b", 0), under: "root")
        let segments = try layout(tree)
        #expect(segments.count == 2)
        #expect(approx(segments[0].endAngle, .pi))
        #expect(approx(segments[1].endAngle, .pi * 2))
        #expect(segments.allSatisfy { $0.totalSize == 1 })
    }

    @Test func emptyFolderAdvancesTheCursorWithoutChildren() throws {
        var tree = LayoutTree(root: folder("root", 4))
        tree.add(folder("empty", 2, files: 0), under: "root")
        tree.add(file("after", 2), under: "root")
        let segments = try layout(tree)
        #expect(segments.map(\.id) == ["empty", "after"])
        #expect(approx(segments[1].startAngle, .pi))
    }

    @Test func tinySiblingsPoolIntoOneAggregate() throws {
        var tree = LayoutTree(root: folder("root", 1_003))
        tree.add(file("large", 1_000), under: "root")
        tree.add(file("tiny-1", 1), under: "root")
        tree.add(file("tiny-2", 1), under: "root")
        tree.add(folder("tiny-dir", 1, files: 5), under: "root")
        let segments = try layout(tree, depthLimit: 1)

        #expect(segments.count == 2)
        let aggregate = try #require(segments.last)
        #expect(aggregate.isAggregate)
        #expect(aggregate.id == "aggregate-large")
        #expect(aggregate.nodeID == nil)
        #expect(aggregate.label == "Smaller Items")
        #expect(aggregate.parentFolderID == "root")
        #expect(aggregate.totalSize == 3)
        // Files count one each; a folder counts its descendant files.
        #expect(aggregate.itemCount == 7)
        #expect(aggregate.colorToken.role == .aggregate)
        #expect(approx(aggregate.startAngle, .pi * 2 * 1_000 / 1_003))
        #expect(approx(aggregate.endAngle, .pi * 2))
    }

    @Test func aLoneTinyChildIsNotWrappedInAnAggregate() throws {
        var tree = LayoutTree(root: folder("root", 1_001))
        tree.add(file("large", 1_000), under: "root")
        tree.add(file("tiny", 1), under: "root")
        let segments = try layout(tree, depthLimit: 1)
        #expect(segments.map(\.id) == ["large", "tiny"])
        #expect(!segments.contains { $0.isAggregate })
    }

    @Test func expandedAggregateLaysOutEveryChild() throws {
        var tree = LayoutTree(root: folder("root", 1_003))
        tree.add(file("large", 1_000), under: "root")
        for index in 1...3 {
            tree.add(file("tiny-\(index)", 1), under: "root")
        }
        let segments = try layout(tree, depthLimit: 1, expandedAggregateIDs: ["root"])
        #expect(segments.map(\.id) == ["large", "tiny-1", "tiny-2", "tiny-3"])
    }

    @Test func hiddenThenFreeSpaceTrailTheTopRing() throws {
        var tree = LayoutTree(root: folder("root", 8))
        tree.add(file("a", 6), under: "root")
        tree.add(file("b", 2), under: "root")
        let segments = try layout(tree, depthLimit: 2, freeSpaceBytes: 4, hiddenSpaceBytes: 4)
        #expect(segments.map(\.id) == ["a", "b", SunburstLayout.hiddenSpaceSegmentID, SunburstLayout.freeSpaceSegmentID])

        let hidden = segments[2]
        let free = segments[3]
        #expect(approx(segments[1].endAngle, .pi))
        #expect(approx(hidden.startAngle, .pi) && approx(hidden.endAngle, .pi * 1.5))
        #expect(approx(free.startAngle, .pi * 1.5) && approx(free.endAngle, .pi * 2))
        #expect(hidden.label == "Hidden" && free.label == "Free")
        #expect(hidden.isHiddenSpace && !hidden.isFreeSpace)
        #expect(free.isFreeSpace && !free.isHiddenSpace)
        #expect(free.nodeID == nil && hidden.nodeID == nil)
        #expect(free.totalSize == 4 && hidden.totalSize == 4)
        #expect(free.depth == 0 && hidden.depth == 0)
        // The synthetic arcs don't advance the color cursor.
        #expect(approx(segments[1].colorToken.midpoint, 0.875))
    }

    @Test func nonPositiveSyntheticBytesAddNoArcs() throws {
        let tree = nestedTree()
        let plain = try layout(tree)
        let negative = try layout(tree, freeSpaceBytes: -10, hiddenSpaceBytes: 0)
        #expect(negative == plain)
        let freeOnly = try layout(tree, depthLimit: 1, freeSpaceBytes: 8)
        #expect(freeOnly.map(\.id) == ["dir", "f", SunburstLayout.freeSpaceSegmentID])
        #expect(approx(freeOnly[2].startAngle, .pi))
    }

    @Test func throwingCancellationCheckAbortsTheLayout() {
        let tree = nestedTree()
        #expect(throws: LayoutCancelled.self) {
            _ = try SunburstLayout.segments(
                in: tree, rootID: tree.rootID, depthLimit: 3,
                cancellationCheck: { throw LayoutCancelled() }
            )
        }
        // A check that trips mid-recursion aborts too, rather than returning a partial ring.
        var calls = 0
        #expect(throws: LayoutCancelled.self) {
            _ = try SunburstLayout.segments(
                in: tree, rootID: tree.rootID, depthLimit: 3,
                cancellationCheck: {
                    calls += 1
                    if calls > 4 { throw LayoutCancelled() }
                }
            )
        }
    }

    @Test func cloudOnlyFilesWeighInOnlyWithTheToggle() throws {
        var tree = LayoutTree(root: LayoutNode(id: "root", isDirectory: true, allocatedSize: 100, cloudOnlyLogicalSize: 100))
        tree.add(file("local", 100), under: "root")
        tree.add(LayoutNode(id: "cloud", cloudOnlyLogicalSize: 100, isDataless: true), under: "root")

        let off = try layout(tree, depthLimit: 1)
        let on = try layout(tree, depthLimit: 1, includeCloudOnly: true)
        let cloudOff = try #require(off.first { $0.id == "cloud" })
        let cloudOn = try #require(on.first { $0.id == "cloud" })
        #expect(cloudOff.isDataless && cloudOn.isDataless)
        #expect(cloudOff.totalSize == 1 && cloudOn.totalSize == 100)
        #expect(approx(cloudOn.startAngle, .pi) && approx(cloudOn.endAngle, .pi * 2))
        #expect(off.first { $0.id == "local" }?.isDataless == false)
    }

    @Test func allCloudFolderIsDashedAndOpensOnlyWithTheToggle() throws {
        var tree = LayoutTree(root: LayoutNode(id: "root", isDirectory: true, allocatedSize: 10, cloudOnlyLogicalSize: 50))
        tree.add(file("local", 10), under: "root")
        tree.add(LayoutNode(id: "icloud", isDirectory: true, cloudOnlyLogicalSize: 50), under: "root")
        tree.add(LayoutNode(id: "doc", cloudOnlyLogicalSize: 50, isDataless: true), under: "icloud")

        let off = try layout(tree)
        let on = try layout(tree, includeCloudOnly: true)
        #expect(off.first { $0.id == "icloud" }?.isDataless == true)
        #expect(!off.contains { $0.id == "doc" })
        #expect(on.contains { $0.id == "doc" && $0.depth == 1 })
    }

    @Test func packagesActAsFilesUntilTheirChildrenAreSpliced() {
        var tree = LayoutTree(root: folder("root", 4))
        tree.add(LayoutNode(id: "opaque.app", isDirectory: true, isPackage: true, allocatedSize: 2), under: "root")
        tree.add(LayoutNode(id: "open.app", isDirectory: true, isPackage: true, allocatedSize: 2), under: "root")
        tree.add(file("inside", 2), under: "open.app")

        #expect(!SunburstLayout.isSunburstFolder(tree.nodes["opaque.app"]!, in: tree))
        #expect(SunburstLayout.isSunburstFolder(tree.nodes["open.app"]!, in: tree))
        #expect(SunburstLayout.isSunburstFolder(tree.nodes["root"]!, in: tree))
        #expect(!SunburstLayout.isSunburstFolder(tree.nodes["inside"]!, in: tree))
    }

    @Test func colorCoordinateSubdividesAlongThePath() throws {
        let tree = nestedTree()
        let root = try #require(SunburstLayout.colorCoordinate(for: "root", in: tree))
        #expect(root.start == 0 && root.span == 1 && root.depth == 0)

        let dir = try #require(SunburstLayout.colorCoordinate(for: "dir", in: tree))
        #expect(approx(dir.start, 0) && approx(dir.span, 0.75) && dir.depth == 1)

        let y = try #require(SunburstLayout.colorCoordinate(for: "y", in: tree))
        #expect(approx(y.start, 0.5) && approx(y.span, 0.25) && y.depth == 2)

        #expect(SunburstLayout.colorCoordinate(for: "missing", in: tree) == nil)
    }

    @Test func colorCoordinateRejectsANodeItsParentDoesNotList() throws {
        var tree = nestedTree()
        tree.add(folder("orphan", 4), under: "root", listed: false)
        tree.add(file("leaf", 4), under: "orphan")
        #expect(SunburstLayout.colorCoordinate(for: "orphan", in: tree) == nil)

        // Laying out from such a node falls back to a fresh full-wheel coordinate.
        let segments = try layout(tree, rootID: "orphan")
        let leaf = try #require(segments.first)
        #expect(leaf.colorToken.depth == 1)
        #expect(approx(leaf.colorToken.midpoint, 0.5))
    }

    @Test func outermostFolderRingTakesTheFullCircle() throws {
        let tree = nestedTree()
        let ring = SunburstLayout.ringSegments(forFolder: "dir", in: tree, depth: 3)
        #expect(ring.map(\.id) == ["x", "y"])
        #expect(approx(ring[0].endAngle, .pi * 2 * 4 / 6))
        #expect(approx(ring[1].endAngle, .pi * 2))
        #expect(ring.allSatisfy { $0.depth == 3 })

        let metrics = SunburstRingMetrics(depthLimit: 4)
        #expect(approx(ring[0].innerRadius, metrics.innerRadius(depth: 3)))
        #expect(approx(ring[0].outerRadius, metrics.drawnOuterRadius(depth: 3)))
        // Same color coordinates the full layout gives these nodes.
        let full = try layout(tree)
        #expect(ring[0].colorToken == full.first { $0.id == "x" }?.colorToken)

        let rootRing = SunburstLayout.ringSegments(forFolder: "root", in: tree, depth: 0)
        #expect(rootRing.map(\.id) == ["dir", "f"])
        #expect(approx(rootRing[0].colorToken.midpoint, 0.375))
    }

    @Test func folderRingIsEmptyForUnknownOrChildlessFolders() {
        var tree = nestedTree()
        tree.add(folder("empty", 0, files: 0), under: "root")
        #expect(SunburstLayout.ringSegments(forFolder: "missing", in: tree, depth: 1).isEmpty)
        #expect(SunburstLayout.ringSegments(forFolder: "empty", in: tree, depth: 1).isEmpty)
    }

    @Test func protocolDefaultsTreatNodesAsFullyLocal() {
        let node = PlainNode(id: "n", name: "n", isDirectory: false, isPackage: false, allocatedSize: 42, descendantFileCount: 1)
        #expect(node.cloudOnlyLogicalSize == 0)
        #expect(!node.isDataless)
        #expect(node.displayWeight(includingCloudOnly: false) == 42)
        #expect(node.displayWeight(includingCloudOnly: true) == 42)
    }
}

@Suite struct SunburstArcGeometryTests {
    @Test func normalArcsInsetHalfTheSeamPerEdge() {
        let (start, end) = SunburstArcGeometry.seamInsetAngles(
            startRadians: 0, endRadians: 1, innerRadius: 0.4, outerRadius: 0.6
        )
        let expected = (SunburstLayout.angularSeam / 2) / 0.5
        #expect(approx(start, expected))
        #expect(approx(end, 1 - expected))
    }

    @Test func fullCircleAndEmptyArcsStaySealed() {
        let full = SunburstArcGeometry.seamInsetAngles(
            startRadians: 0, endRadians: .pi * 2, innerRadius: 0.4, outerRadius: 0.6
        )
        #expect(full.start == 0 && full.end == .pi * 2)
        let empty = SunburstArcGeometry.seamInsetAngles(
            startRadians: 1, endRadians: 1, innerRadius: 0.4, outerRadius: 0.6
        )
        #expect(empty.start == 1 && empty.end == 1)
        let reversed = SunburstArcGeometry.seamInsetAngles(
            startRadians: 2, endRadians: 1, innerRadius: 0.4, outerRadius: 0.6
        )
        #expect(reversed.start == 2 && reversed.end == 1)
    }

    @Test func degenerateRadiusSkipsTheInset() {
        let arc = SunburstArcGeometry.seamInsetAngles(
            startRadians: 0, endRadians: 1, innerRadius: 0, outerRadius: 0.001
        )
        #expect(arc.start == 0 && arc.end == 1)
    }

    @Test func tinySliversCapTheInsetAtAFractionOfTheirSpan() {
        let span = 0.001
        let arc = SunburstArcGeometry.seamInsetAngles(
            startRadians: 0, endRadians: span, innerRadius: 0.4, outerRadius: 0.6
        )
        #expect(approx(arc.start, span * 0.18))
        #expect(approx(arc.end, span - span * 0.18))
        #expect(arc.start < arc.end)
    }
}
