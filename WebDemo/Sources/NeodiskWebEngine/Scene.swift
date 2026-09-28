//
//  Scene.swift
//  NeodiskWebEngine
//
//  Port of NeodiskUI/Treemap/TreemapScene.swift onto the flattened index
//  tree: what goes into the map (squarified layout via TreemapKit's real
//  TreemapLayout, cushion ridges, min-cell culling, "smaller items"
//  aggregation, flat nesting with header strips, free/hidden-space blocks,
//  cloud-only hatching, highlight dimming, branch hues via SunburstCore) —
//  line for line, minus Foundation. Keep in sync with TreemapScene.build.
//

import TreemapKit
import SunburstCore

/// Synthetic node indices for the volume's free / hidden space blocks.
let freeSpaceIndex: Int32 = -2
let hiddenSpaceIndex: Int32 = -3

enum ColorMode: Int32 {
    case kind = 0
    case age = 1
    case branch = 2
}

struct CellFlags {
    static let directory: UInt32 = 1 << 0
    static let container: UInt32 = 1 << 1
    static let aggregate: UInt32 = 1 << 2
    static let freeSpace: UInt32 = 1 << 3
    static let hiddenSpace: UInt32 = 1 << 4
    static let dataless: UInt32 = 1 << 5
}

struct SceneLabel {
    var node: Int32
    var rect: CGRect
    var isHeader: Bool
}

/// Scene parameters, kept so `rect(forNode:)` re-runs the layout exactly as
/// `build` did (TreemapScene remembers the same inputs).
struct SceneInputs {
    var root: Int32 = 0
    var size = CGSize.zero
    var viewportScale: Double = 1
    var viewportOrigin = CGPoint.zero
    var style: TreemapStyle = .cushion
    var labelScale: Double = 1
    var colorMode: ColorMode = .kind
    var hasHighlight = false
    var freeBytes: Double = 0
    var hiddenBytes: Double = 0
    var includingCloudOnly = false
    var background = SIMD3<Float>(18, 18, 22) / 255
}

enum Scene {
    nonisolated(unsafe) static var inputs = SceneInputs()
    nonisolated(unsafe) static var cells: [TreemapCell] = []
    nonisolated(unsafe) static var cellNode: [Int32] = []
    nonisolated(unsafe) static var cellFlags: [UInt32] = []
    nonisolated(unsafe) static var cellAggCount: [Double] = []
    nonisolated(unsafe) static var cellAggSize: [Double] = []
    nonisolated(unsafe) static var labels: [SceneLabel] = []
    nonisolated(unsafe) static var renderBounds = CGRect.zero
    nonisolated(unsafe) static var grid = CellGrid(rects: [], bounds: .zero)
    nonisolated(unsafe) static var palette = SunburstPalette.standard

    // MARK: constants (TreemapScene)

    static let rootRidgeHeight = 0.35
    static let ridgeFalloff = 0.85
    static let minSubdivisionArea: Double = 12
    static let minSubdivisionSide: Double = 2
    static let minChildCellArea: Double = 64
    static let flatMinChildCellArea: Double = 120
    static func minChildArea(for style: TreemapStyle) -> Double {
        style == .flat ? flatMinChildCellArea : minChildCellArea
    }
    static func labelMinCellWidth(_ s: Double) -> Double { 80 * s }
    static func labelMinCellHeight(_ s: Double) -> Double { 22 * s }
    static func labelMinCellArea(_ s: Double) -> Double { 4_000 * s * s }
    static let overscanFraction: Double = 0.3
    static let flatContainerInset: Double = 2
    static func flatHeaderHeight(_ s: Double) -> Double { (18 * s).rounded() }
    static func flatMinContainerWidth(_ s: Double) -> Double { 52 * s }
    static func flatMinContainerHeight(_ s: Double) -> Double { flatHeaderHeight(s) + 28 }
    static let flatMaxContainerDepth = 6
    static func flatFolderLabelMinCellWidth(_ s: Double) -> Double { 40 * s }
    static func flatFolderLabelMinCellHeight(_ s: Double) -> Double { 15 * s }

    static func flatContentBounds(of rect: CGRect, scale: Double) -> CGRect? {
        guard rect.width >= flatMinContainerWidth(scale),
              rect.height >= flatMinContainerHeight(scale) else { return nil }
        let header = flatHeaderHeight(scale)
        var content = rect.insetBy(dx: flatContainerInset, dy: flatContainerInset)
        content.origin.y += header
        content.size.height -= header
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }

    static let highlightDesaturation: Float = 0.7
    static let highlightDimBrightness: Float = 0.4
    static func dimmedRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * highlightDesaturation
        return desaturated * highlightDimBrightness
    }
    static let datalessDesaturation: Float = 0.45
    static let datalessDimBrightness: Float = 0.85
    static func datalessRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * datalessDesaturation
        return desaturated * datalessDimBrightness
    }
    static let flatFillOpacity: Float = 0.75
    static func flatComposite(_ rgb: SIMD3<Float>, over backdrop: SIMD3<Float>) -> SIMD3<Float> {
        rgb * flatFillOpacity + backdrop * (1 - flatFillOpacity)
    }
    static let flatBranchDesaturation: Float = 0.18
    static let flatRootFileDim: Float = 0.9
    static let flatDepthDesaturation: Float = 0.03
    static let flatDepthDim: Float = 0.035
    static let flatDepthLimit = 6
    static func flatDepthRamp(_ rgb: SIMD3<Float>, depth: Int) -> SIMD3<Float> {
        let tone = Float(min(max(depth - 1, 0), flatDepthLimit))
        guard tone > 0 else { return rgb }
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * (flatDepthDesaturation * tone)
        return desaturated * (1 - flatDepthDim * tone)
    }
    static let otherRGB = SIMD3<Float>(0.52, 0.52, 0.55)
    static let directoryRGB = SIMD3<Float>(0.33, 0.33, 0.36)
    static let freeSpaceRGB = SIMD3<Float>(0.13, 0.13, 0.16)
    static let hiddenSpaceRGB = SIMD3<Float>(0.30, 0.30, 0.33)

    // MARK: node helpers

    @inline(__always) static func weight(_ node: Int32) -> Double {
        if node == freeSpaceIndex { return inputs.freeBytes }
        if node == hiddenSpaceIndex { return inputs.hiddenBytes }
        return Tree.weight[Int(node)]
    }
    @inline(__always) static func isSynthetic(_ node: Int32) -> Bool { node < 0 }

    /// A directory's laid-out siblings: children with weight > 0 (already
    /// weight-sorted), plus — at the scene root — the synthetic free/hidden
    /// blocks merged in by weight (TreemapScene.layoutSiblings).
    static func layoutSiblings(of node: Int32, isRoot: Bool) -> [Int32] {
        let first = Int(Tree.firstChild[Int(node)])
        let n = Int(Tree.childCount[Int(node)])
        var out: [Int32] = []
        out.reserveCapacity(n + 2)
        for i in first..<(first + n) where Tree.weight[i] > 0 {
            out.append(Int32(i))
        }
        if isRoot {
            for synthetic in [freeSpaceIndex, hiddenSpaceIndex] where weight(synthetic) > 0 {
                let w = weight(synthetic)
                var at = out.count
                for (k, existing) in out.enumerated() where weight(existing) < w {
                    at = k
                    break
                }
                out.insert(synthetic, at: at)
            }
        }
        return out
    }

    struct ChildLayout {
        var rects: [CGRect]
        var keptCount: Int
        var aggregateRect: CGRect?
    }

    static func layoutChildren(
        _ children: [Int32],
        in rect: CGRect,
        disableAggregation: Bool,
        minChildArea: Double
    ) -> ChildLayout {
        var totalSize: Double = 0
        for c in children { totalSize += weight(c) }
        var keptCount = children.count
        if !disableAggregation, minChildArea > 0, totalSize > 0 {
            let areaPerByte = Double(rect.width * rect.height) / totalSize
            while keptCount > 0, weight(children[keptCount - 1]) * areaPerByte < minChildArea {
                keptCount -= 1
            }
        }
        if children.count - keptCount < 2 {
            var weights: [Double] = []
            weights.reserveCapacity(children.count)
            for c in children { weights.append(weight(c)) }
            let rects = TreemapLayout.squarify(weights: weights, in: rect)
            return ChildLayout(rects: rects, keptCount: children.count, aggregateRect: nil)
        }
        var weights: [Double] = []
        weights.reserveCapacity(keptCount + 1)
        for c in children[..<keptCount] { weights.append(weight(c)) }
        var tail: Double = 0
        for c in children[keptCount...] { tail += weight(c) }
        weights.append(tail)
        var rects = TreemapLayout.squarify(weights: weights, in: rect)
        let aggregateRect = rects.removeLast()
        return ChildLayout(rects: rects, keptCount: keptCount, aggregateRect: aggregateRect)
    }

    // MARK: colors

    static func midpointRGB(midpoint: Double, depth: Int, role: SunburstColorRole, style: TreemapStyle) -> SIMD3<Float> {
        let token = SunburstColorToken(midpoint: midpoint, depth: depth, role: role)
        let rgb = SunburstColorResolver.rgb(for: token, palette: palette)
        guard role == .normal else { return rgb * flatRootFileDim }
        guard style == .flat else { return rgb }
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        return rgb + (gray - rgb) * flatBranchDesaturation
    }

    static func resolvedRGB(
        for node: Int32,
        color: (start: Double, span: Double)?,
        globalDepth: Int,
        style: TreemapStyle
    ) -> SIMD3<Float> {
        switch inputs.colorMode {
        case .kind, .age:
            // palette.js resolved the catalog color / age ramp (directories
            // already carry directoryRGB).
            return Tree.color(node)
        case .branch:
            let depth = max(globalDepth, 1)
            var role = SunburstColorRole.normal
            if depth <= 1, !Tree.isSunburstFolder(node) {
                role = .file
            }
            let midpoint = color.map { $0.start + $0.span / 2 } ?? 0.5
            return midpointRGB(midpoint: midpoint, depth: depth, role: role, style: style)
        }
    }

    @inline(__always) static func matches(_ node: Int32) -> Bool {
        node >= 0 && Tree.flag(node, NodeFlags.highlightMatch)
    }

    // MARK: build

    static func build() {
        cells.removeAll(keepingCapacity: true)
        cellNode.removeAll(keepingCapacity: true)
        cellFlags.removeAll(keepingCapacity: true)
        cellAggCount.removeAll(keepingCapacity: true)
        cellAggSize.removeAll(keepingCapacity: true)
        labels.removeAll(keepingCapacity: true)

        let size = inputs.size
        let style = inputs.style
        let labelScale = inputs.labelScale
        let colorMode = inputs.colorMode
        let hasHighlight = inputs.hasHighlight
        let includingCloudOnly = inputs.includingCloudOnly
        let background = inputs.background
        let rootID = inputs.root
        guard size.width >= 1, size.height >= 1, Tree.has(rootID) else {
            renderBounds = CGRect(origin: .zero, size: size)
            grid = CellGrid(rects: [], bounds: renderBounds)
            return
        }

        let visibleBounds = CGRect(origin: .zero, size: size)
        let rootRect = CGRect(
            x: -inputs.viewportOrigin.x,
            y: -inputs.viewportOrigin.y,
            width: size.width * inputs.viewportScale,
            height: size.height * inputs.viewportScale
        )
        renderBounds = intersection(
            visibleBounds.insetBy(dx: -size.width * overscanFraction, dy: -size.height * overscanFraction),
            rootRect
        )

        let rootDepth = Tree.depth(of: rootID)
        let rootColor: (start: Double, span: Double)?
        if colorMode == .branch {
            if rootID == 0 {
                rootColor = (start: 0, span: 1)
            } else if let c = SunburstLayout.colorCoordinate(for: idString(rootID), in: WebTree(), includeCloudOnly: includingCloudOnly) {
                rootColor = (start: c.start, span: c.span)
            } else {
                rootColor = (start: 0, span: 1)
            }
        } else {
            rootColor = nil
        }

        typealias Entry = (node: Int32, rect: CGRect, surface: CushionSurface, height: Double, isRoot: Bool, color: (start: Double, span: Double)?, depth: Int)
        var stack: [Entry] = [(rootID, rootRect, CushionSurface(), rootRidgeHeight, true, rootColor, 0)]

        while let (node, rect, parentSurface, ridgeHeight, isRoot, color, depth) = stack.popLast() {
            guard rect.width > 0.5, rect.height > 0.5, overlaps(rect, renderBounds) else { continue }

            var surface = parentSurface
            if style == .cushion, !isRoot {
                surface.addRidge(over: rect, height: ridgeHeight)
            }

            let isDir = node >= 0 && Tree.isDirectory(node)
            let subdividable = isDir
                && rect.width * rect.height >= minSubdivisionArea
                && min(rect.width, rect.height) >= minSubdivisionSide

            let childLayoutRect: CGRect?
            if !subdividable {
                childLayoutRect = nil
            } else if style == .flat, !isRoot {
                childLayoutRect = depth < flatMaxContainerDepth ? flatContentBounds(of: rect, scale: labelScale) : nil
            } else {
                childLayoutRect = rect
            }

            if let childLayoutRect {
                let children = layoutSiblings(of: node, isRoot: isRoot)
                if !children.isEmpty {
                    var childColors: [(start: Double, span: Double)?]
                    if let color {
                        var dataTotal: Double = 0
                        for child in children where !isSynthetic(child) { dataTotal += max(weight(child), 1) }
                        var cursor = color.start
                        childColors = []
                        childColors.reserveCapacity(children.count)
                        for child in children {
                            if isSynthetic(child) {
                                childColors.append((start: cursor, span: 0))
                                continue
                            }
                            let span = color.span * (max(weight(child), 1) / max(dataTotal, 1))
                            childColors.append((start: cursor, span: span))
                            cursor += span
                        }
                    } else {
                        childColors = [(start: Double, span: Double)?](repeating: nil, count: children.count)
                    }

                    if style == .flat, !isRoot {
                        var rgb = resolvedRGB(for: node, color: color, globalDepth: rootDepth + depth, style: style)
                        if hasHighlight, !matches(node) { rgb = dimmedRGB(rgb) }
                        let isDataless = includingCloudOnly
                            && Tree.flag(node, NodeFlags.allocZero) && Tree.flag(node, NodeFlags.cloudBytes)
                        if isDataless { rgb = datalessRGB(rgb) }
                        if colorMode != .branch { rgb = flatDepthRamp(rgb, depth: rootDepth + depth) }
                        rgb = flatComposite(rgb, over: background)
                        appendCell(
                            TreemapCell(nodeID: "", rect: rect, rgb: rgb, surface: surface,
                                        isDirectory: true, isContainer: true, isDataless: isDataless),
                            node: node,
                            flags: CellFlags.directory | CellFlags.container | (isDataless ? CellFlags.dataless : 0)
                        )
                        let headerRect = intersection(
                            CGRect(
                                x: rect.minX + flatContainerInset + 4,
                                y: rect.minY + flatContainerInset + 1,
                                width: rect.width - 2 * (flatContainerInset + 4),
                                height: flatHeaderHeight(labelScale) - 4
                            ),
                            visibleBounds
                        )
                        if !headerRect.isEmpty {
                            labels.append(SceneLabel(node: node, rect: headerRect, isHeader: true))
                        }
                    }

                    let childHeight = isRoot ? ridgeHeight : ridgeHeight * ridgeFalloff
                    let layout = layoutChildren(
                        children,
                        in: childLayoutRect,
                        disableAggregation: node >= 0 && Tree.flag(node, NodeFlags.aggregateExpanded),
                        minChildArea: minChildArea(for: style)
                    )
                    for index in 0..<layout.keptCount {
                        stack.append((children[index], layout.rects[index], surface, childHeight, false, childColors[index], depth + 1))
                    }

                    if let aggregateRect = layout.aggregateRect, aggregateRect.width > 0.5, aggregateRect.height > 0.5 {
                        let tail = children[layout.keptCount...]
                        var aggregateSurface = surface
                        if style == .cushion {
                            aggregateSurface.addRidge(over: aggregateRect, height: childHeight)
                        }
                        var itemCount: Double = 0
                        var totalSize: Double = 0
                        var lit = false
                        var allZero = true
                        for t in tail {
                            if t >= 0 {
                                itemCount += Tree.isDirectory(t) ? max(Tree.files[Int(t)], 1) : 1
                                if !Tree.flag(t, NodeFlags.allocZero) { allZero = false }
                                if matches(t) { lit = true }
                            } else {
                                allZero = false
                            }
                            totalSize += weight(t)
                        }
                        var aggregateRGB: SIMD3<Float>
                        if colorMode == .branch {
                            if let color, node != 0 {
                                var tailSpan = 0.0
                                for k in layout.keptCount..<childColors.count { tailSpan += childColors[k]?.span ?? 0 }
                                let tailStart = childColors[layout.keptCount]?.start ?? (color.start + color.span - tailSpan)
                                aggregateRGB = midpointRGB(
                                    midpoint: tailStart + tailSpan / 2,
                                    depth: rootDepth + depth + 1,
                                    role: .normal, style: style
                                )
                            } else {
                                aggregateRGB = SunburstColorResolver.rgb(
                                    for: SunburstColorToken(midpoint: 0, depth: 0, role: .aggregate),
                                    palette: palette
                                )
                            }
                        } else {
                            aggregateRGB = otherRGB
                        }
                        if hasHighlight, !lit { aggregateRGB = dimmedRGB(aggregateRGB) }
                        let aggregateDataless = includingCloudOnly && allZero
                        if aggregateDataless { aggregateRGB = datalessRGB(aggregateRGB) }
                        if style == .flat {
                            if colorMode != .branch {
                                aggregateRGB = flatDepthRamp(aggregateRGB, depth: rootDepth + depth + 1)
                            }
                            aggregateRGB = flatComposite(aggregateRGB, over: background)
                        }
                        appendCell(
                            TreemapCell(nodeID: "", rect: aggregateRect, rgb: aggregateRGB, surface: aggregateSurface,
                                        isDirectory: true,
                                        aggregate: TreemapCell.AggregateInfo(itemCount: Int(itemCount), totalSize: Int64(totalSize)),
                                        isDataless: aggregateDataless),
                            node: node,
                            flags: CellFlags.directory | CellFlags.aggregate | (aggregateDataless ? CellFlags.dataless : 0),
                            aggCount: itemCount, aggSize: totalSize
                        )
                    }
                    continue
                }
            }

            let isFreeSpace = node == freeSpaceIndex
            let isHiddenSpace = node == hiddenSpaceIndex
            var rgb: SIMD3<Float>
            if isFreeSpace {
                rgb = freeSpaceRGB
            } else if isHiddenSpace {
                rgb = hiddenSpaceRGB
            } else {
                rgb = resolvedRGB(for: node, color: color, globalDepth: rootDepth + depth, style: style)
            }
            if hasHighlight, !matches(node) { rgb = dimmedRGB(rgb) }
            let isDataless = includingCloudOnly && node >= 0
                && (Tree.flag(node, NodeFlags.dataless)
                    || (isDir && Tree.flag(node, NodeFlags.allocZero) && Tree.flag(node, NodeFlags.cloudBytes)))
            if isDataless { rgb = datalessRGB(rgb) }
            if style == .flat {
                if colorMode != .branch { rgb = flatDepthRamp(rgb, depth: rootDepth + depth) }
                rgb = flatComposite(rgb, over: background)
            }
            var flags: UInt32 = 0
            if isDir { flags |= CellFlags.directory }
            if isFreeSpace { flags |= CellFlags.freeSpace }
            if isHiddenSpace { flags |= CellFlags.hiddenSpace }
            if isDataless { flags |= CellFlags.dataless }
            appendCell(
                TreemapCell(nodeID: "", rect: rect, rgb: rgb, surface: surface, isDirectory: isDir,
                            isFreeSpace: isFreeSpace, isHiddenSpace: isHiddenSpace, isDataless: isDataless),
                node: node, flags: flags
            )

            let visiblePart = intersection(rect, visibleBounds)
            if style == .flat, isDir {
                if visiblePart.width >= flatFolderLabelMinCellWidth(labelScale),
                   visiblePart.height >= flatFolderLabelMinCellHeight(labelScale) {
                    labels.append(SceneLabel(node: node, rect: visiblePart, isHeader: false))
                }
            } else if visiblePart.width >= labelMinCellWidth(labelScale),
                      visiblePart.height >= labelMinCellHeight(labelScale),
                      visiblePart.width * visiblePart.height >= labelMinCellArea(labelScale) {
                labels.append(SceneLabel(node: node, rect: visiblePart, isHeader: false))
            }
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(cells.count)
        for cell in cells { rects.append(cell.rect) }
        grid = CellGrid(rects: rects, bounds: renderBounds)
    }

    private static func appendCell(_ cell: TreemapCell, node: Int32, flags: UInt32, aggCount: Double = 0, aggSize: Double = 0) {
        cells.append(cell)
        cellNode.append(node)
        cellFlags.append(flags)
        cellAggCount.append(aggCount)
        cellAggSize.append(aggSize)
    }

    // MARK: queries

    /// The deepest cell containing `point` (TreemapScene.cell(at:)).
    static func cell(at point: CGPoint, directoriesOnly: Bool = false) -> Int {
        let candidates = grid.candidateIndices(at: point)
        var deepest = -1
        if let candidates {
            for index in candidates {
                let i = Int(index)
                if directoriesOnly, cellFlags[i] & CellFlags.directory == 0 { continue }
                if cells[i].rect.contains(point), i > deepest { deepest = i }
            }
        } else {
            for i in stride(from: cells.count - 1, through: 0, by: -1) {
                if directoriesOnly, cellFlags[i] & CellFlags.directory == 0 { continue }
                if cells[i].rect.contains(point) { return i }
            }
        }
        return deepest
    }

    /// The on-screen rect of an arbitrary node, re-running the layout along
    /// its path from the scene root (TreemapScene.rect(forNodeID:)).
    static func rect(forNode target: Int32) -> CGRect? {
        let size = inputs.size
        guard size.width >= 1, size.height >= 1, Tree.has(target) else { return nil }
        var chain: [Int32] = []
        var cur = target
        while cur >= 0 {
            chain.append(cur)
            if cur == inputs.root { break }
            cur = Tree.parent[Int(cur)]
        }
        guard chain.last == inputs.root else { return nil }
        chain.reverse()

        var rect = CGRect(
            x: -inputs.viewportOrigin.x,
            y: -inputs.viewportOrigin.y,
            width: size.width * inputs.viewportScale,
            height: size.height * inputs.viewportScale
        )
        var depth = 0
        var i = 0
        while i + 1 < chain.count {
            let parent = chain[i]
            let child = chain[i + 1]
            let children = layoutSiblings(of: parent, isRoot: parent == inputs.root)
            guard let childIndex = children.firstIndex(of: child) else { return nil }
            var layoutRect = rect
            if inputs.style == .flat, parent != inputs.root {
                guard depth < flatMaxContainerDepth,
                      let content = flatContentBounds(of: rect, scale: inputs.labelScale) else {
                    return rect
                }
                layoutRect = content
            }
            let layout = layoutChildren(
                children,
                in: layoutRect,
                disableAggregation: Tree.flag(parent, NodeFlags.aggregateExpanded),
                minChildArea: minChildArea(for: inputs.style)
            )
            if childIndex < layout.keptCount {
                rect = layout.rects[childIndex]
            } else if let aggregateRect = layout.aggregateRect {
                return aggregateRect
            } else {
                return nil
            }
            depth += 1
            i += 1
        }
        return rect
    }
}

// MARK: - Geometry helpers (CGShims carries only what TreemapKit needs)

@inline(__always) func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}

func intersection(_ a: CGRect, _ b: CGRect) -> CGRect {
    let x0 = max(a.minX, b.minX)
    let y0 = max(a.minY, b.minY)
    let x1 = min(a.maxX, b.maxX)
    let y1 = min(a.maxY, b.maxY)
    guard x1 > x0, y1 > y0 else { return CGRect(x: x0, y: y0, width: 0, height: 0) }
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

/// Uniform-bucket spatial index over the scene's cells (TreemapScene's CellGrid).
struct CellGrid {
    private let boundsOrigin: CGPoint
    private let bucketWidth: Double
    private let bucketHeight: Double
    private let columns: Int
    private let rows: Int
    private let buckets: [[Int32]]

    init(rects: [CGRect], bounds: CGRect) {
        guard !rects.isEmpty, bounds.width >= 1, bounds.height >= 1 else {
            boundsOrigin = bounds.origin
            bucketWidth = max(bounds.width, 1)
            bucketHeight = max(bounds.height, 1)
            columns = 0
            rows = 0
            buckets = []
            return
        }
        let targetBucketCount = min(4_096, max(1, rects.count / 4))
        let aspect = bounds.width / bounds.height
        let columnCount = max(1, Int((Double(targetBucketCount) * aspect).squareRoot().rounded()))
        let rowCount = max(1, (targetBucketCount + columnCount - 1) / columnCount)
        boundsOrigin = bounds.origin
        bucketWidth = bounds.width / Double(columnCount)
        bucketHeight = bounds.height / Double(rowCount)
        columns = columnCount
        rows = rowCount
        var filled = [[Int32]](repeating: [], count: columnCount * rowCount)
        for (index, r) in rects.enumerated() {
            let rect = intersection(r, bounds)
            guard !rect.isEmpty else { continue }
            let minColumn = max(0, Int((rect.minX - bounds.minX) / bucketWidth))
            let maxColumn = min(columnCount - 1, Int((rect.maxX - bounds.minX) / bucketWidth))
            let minRow = max(0, Int((rect.minY - bounds.minY) / bucketHeight))
            let maxRow = min(rowCount - 1, Int((rect.maxY - bounds.minY) / bucketHeight))
            guard minColumn <= maxColumn, minRow <= maxRow else { continue }
            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    filled[row * columnCount + column].append(Int32(index))
                }
            }
        }
        buckets = filled
    }

    func candidateIndices(at point: CGPoint) -> [Int32]? {
        guard columns > 0, rows > 0 else { return nil }
        let px = (point.x - boundsOrigin.x) / bucketWidth
        let py = (point.y - boundsOrigin.y) / bucketHeight
        guard px >= 0, py >= 0 else { return nil }
        let column = Int(px)
        let row = Int(py)
        guard column < columns, row < rows else { return nil }
        return buckets[row * columns + column]
    }
}
