//
//  TreemapScene.swift
//  Neodisk
//
//  Builds the flat list of renderable treemap cells for a subtree: squarified
//  layout plus accumulated cushion surface coefficients (van Wijk & van de
//  Wetering, "Cushion Treemaps", 1999).
//

import CoreGraphics
import Foundation
import TreemapKit
import NeodiskKit

/// What a treemap cell's color means: the node's file kind (the default) or
/// its modification-age bucket, measured against the snapshot's scan date.
enum TreemapColorMode: Equatable, Sendable {
    case kind
    case age(referenceDate: Date)
}

/// A subset of the map lit at full color while everything else dims: one
/// kind (the kind drill-in), one age bucket (the Age tab drill-in, valid
/// only with the matching `.age` color mode), or an explicit set of node
/// IDs (duplicate groups).
enum TreemapHighlight: Equatable, Sendable {
    case kind(String)
    case ageBucket(AgeBucket)
    case nodes(Set<String>)
}

struct TreemapScene: Sendable {
    /// A name drawn on top of a cell large enough to carry one.
    struct CellLabel: Sendable, Identifiable {
        let id: String
        let text: String
        let rect: CGRect
    }

    let rootID: String
    let size: CGSize
    let viewport: TreemapViewport
    /// The region actually rasterized, in view coordinates. A superset of the
    /// visible bounds when zoomed in (overscan), so panning reveals crisp
    /// content instead of unrendered black.
    let renderBounds: CGRect
    let cells: [TreemapCell]
    let labels: [CellLabel]
    /// Directories whose "smaller items" aggregation is disabled because the
    /// user asked to see their contents individually.
    let expandedAggregateIDs: Set<String>
    /// Synthetic node representing volume free space, laid out as an extra
    /// child of the root; nil when the feature is off or not a volume scan.
    var freeSpaceNode: FileNodeRecord?
    /// Synthetic node representing volume hidden space (purgeable space,
    /// local snapshots, files the scan could not see), laid out like the
    /// free-space node; nil when the feature is off or nothing is hidden.
    var hiddenSpaceNode: FileNodeRecord?
    /// Whether cloud-only (dataless) bytes count toward layout weight; mirrors
    /// the model's `showsCloudOnlyFiles`. `rect(forNodeID:)` re-runs the layout
    /// and must weigh children exactly as `build` did, so the scene remembers.
    let includingCloudOnly: Bool
    /// Coarse spatial buckets over `cells` so hover hit-testing doesn't
    /// linear-scan tens of thousands of cells per mouse-move.
    private let cellGrid: CellGrid

    nonisolated init(
        rootID: String,
        size: CGSize,
        viewport: TreemapViewport,
        renderBounds: CGRect,
        cells: [TreemapCell],
        labels: [CellLabel],
        expandedAggregateIDs: Set<String>,
        freeSpaceNode: FileNodeRecord? = nil,
        hiddenSpaceNode: FileNodeRecord? = nil,
        includingCloudOnly: Bool = false
    ) {
        self.rootID = rootID
        self.size = size
        self.viewport = viewport
        self.renderBounds = renderBounds
        self.cells = cells
        self.labels = labels
        self.expandedAggregateIDs = expandedAggregateIDs
        self.freeSpaceNode = freeSpaceNode
        self.hiddenSpaceNode = hiddenSpaceNode
        self.includingCloudOnly = includingCloudOnly
        self.cellGrid = CellGrid(cells: cells, bounds: renderBounds)
    }

    /// Cushion parameters: initial ridge height and per-level falloff.
    /// The zoom root itself gets no ridge — a single canvas-wide cushion
    /// darkens the whole map's edges without adding structure.
    nonisolated static let rootRidgeHeight = 0.35
    nonisolated static let ridgeFalloff = 0.85
    /// Rects smaller than this (in layout points) are not subdivided further;
    /// the directory is drawn as a single cell so the map has no holes.
    nonisolated static let minSubdivisionArea: CGFloat = 12
    nonisolated static let minSubdivisionSide: CGFloat = 2
    /// Children that would occupy less than this many square points get
    /// merged into a single "smaller items" cell per directory.
    nonisolated static let minChildCellArea: CGFloat = 64
    /// Files at least this large get their name drawn on the map, provided
    /// their cell has room for it.
    /// Files get their name drawn once their on-screen cell is big enough to
    /// carry it legibly — zooming in reveals more names as cells grow.
    nonisolated static let labelMinCellWidth: CGFloat = 80
    nonisolated static let labelMinCellHeight: CGFloat = 22
    nonisolated static let labelMinCellArea: CGFloat = 4_000
    /// Extra margin rendered around the visible window (fraction of the view
    /// size per side) so pans show real pixels while the next render lands.
    nonisolated static let overscanFraction: CGFloat = 0.3
    /// Suffix of the synthetic free-space node's id (root id + suffix).
    private nonisolated static let freeSpaceNodeSuffix = "/__free-space__"
    nonisolated static let freeSpaceRGB = SIMD3<Float>(0.13, 0.13, 0.16)
    /// Suffix of the synthetic hidden-space node's id (root id + suffix).
    private nonisolated static let hiddenSpaceNodeSuffix = "/__hidden-space__"
    /// A lighter neutral than the near-black free-space cell, so the two
    /// synthetic blocks read as related but distinct quiet areas.
    nonisolated static let hiddenSpaceRGB = SIMD3<Float>(0.30, 0.30, 0.33)

    /// Kind-highlight dimming: non-matching cells blend this far toward
    /// their own gray (desaturation) and drop to this brightness, so the
    /// highlighted kind's full-color cells pop against a muted map.
    nonisolated static let highlightDesaturation: Float = 0.7
    nonisolated static let highlightDimBrightness: Float = 0.4

    /// The muted color a cell takes when a kind highlight is active and the
    /// cell doesn't match: desaturate toward gray, then darken.
    nonisolated static func dimmedRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * highlightDesaturation
        return desaturated * highlightDimBrightness
    }

    nonisolated static func build(
        store: FileTreeStore,
        rootID: String,
        size: CGSize,
        catalog: FileKindCatalog,
        colorMode: TreemapColorMode = .kind,
        highlight: TreemapHighlight? = nil,
        expandedAggregateIDs: Set<String> = [],
        viewport: TreemapViewport = .identity,
        freeSpaceBytes: Int64? = nil,
        hiddenSpaceBytes: Int64? = nil,
        includingCloudOnly: Bool = false,
        palette: VizPalette = .standard
    ) -> TreemapScene {
        var cells: [TreemapCell] = []
        var labels: [CellLabel] = []
        guard size.width >= 1, size.height >= 1, let root = store.node(id: rootID) else {
            return TreemapScene(
                rootID: rootID, size: size, viewport: viewport,
                renderBounds: CGRect(origin: .zero, size: size),
                cells: [], labels: [],
                expandedAggregateIDs: expandedAggregateIDs,
                includingCloudOnly: includingCloudOnly
            )
        }

        let freeSpaceNode = makeFreeSpaceNode(rootID: rootID, root: root, bytes: freeSpaceBytes)
        let hiddenSpaceNode = makeHiddenSpaceNode(rootID: rootID, root: root, bytes: hiddenSpaceBytes)

        // The virtual canvas is size × scale, positioned so that emitted
        // geometry lands directly in view coordinates. Rasterization covers
        // the visible window plus an overscan margin (clamped to the canvas);
        // subtrees outside that region are pruned.
        let visibleBounds = CGRect(origin: .zero, size: size)
        let rootRect = CGRect(
            x: -viewport.origin.x,
            y: -viewport.origin.y,
            width: size.width * viewport.scale,
            height: size.height * viewport.scale
        )
        let renderBounds = visibleBounds
            .insetBy(dx: -size.width * overscanFraction, dy: -size.height * overscanFraction)
            .intersection(rootRect)

        var stack: [(node: FileNodeRecord, rect: CGRect, surface: CushionSurface, height: Double, isRoot: Bool)] = [
            (root, rootRect, CushionSurface(), rootRidgeHeight, true)
        ]

        while let (node, rect, parentSurface, ridgeHeight, isRoot) = stack.popLast() {
            guard rect.width > 0.5, rect.height > 0.5, rect.intersects(renderBounds) else { continue }

            var surface = parentSurface
            if !isRoot {
                surface.addRidge(over: rect, height: ridgeHeight)
            }

            let subdividable = node.isDirectory
                && rect.width * rect.height >= minSubdivisionArea
                && min(rect.width, rect.height) >= minSubdivisionSide

            if subdividable {
                let filtered = store.children(of: node.id)
                    .filter { $0.displayWeight(includingCloudOnly: includingCloudOnly) > 0 }
                let syntheticNodes = isRoot ? [freeSpaceNode, hiddenSpaceNode].compactMap { $0 } : []
                let children = layoutSiblings(
                    filtered, synthetic: syntheticNodes, includingCloudOnly: includingCloudOnly
                )
                if !children.isEmpty {
                    let childHeight = isRoot ? ridgeHeight : ridgeHeight * ridgeFalloff
                    let layout = layoutChildren(
                        children,
                        in: rect,
                        includingCloudOnly: includingCloudOnly,
                        disableAggregation: expandedAggregateIDs.contains(node.id)
                    )

                    for (child, childRect) in zip(children[..<layout.keptCount], layout.rects) {
                        stack.append((child, childRect, surface, childHeight, false))
                    }

                    if let aggregateRect = layout.aggregateRect,
                       aggregateRect.width > 0.5, aggregateRect.height > 0.5 {
                        let tail = children[layout.keptCount...]
                        var aggregateSurface = surface
                        aggregateSurface.addRidge(over: aggregateRect, height: childHeight)
                        let itemCount = tail.reduce(0) {
                            $0 + ($1.isDirectory ? max($1.descendantFileCount, 1) : 1)
                        }
                        // With a highlight active, an aggregate stays lit
                        // only when a directly merged node matches — the tail
                        // is already in hand, so this check is cheap. Matches
                        // hidden deeper inside merged subdirectories are not
                        // searched for; those aggregates dim.
                        var aggregateRGB = FileKindCatalog.otherRGB
                        if let highlight {
                            let lit = tail.contains {
                                matches($0, highlight: highlight, colorMode: colorMode, catalog: catalog)
                            }
                            if !lit { aggregateRGB = dimmedRGB(aggregateRGB) }
                        }
                        // Hatch the merged cell only when every node folded
                        // into it is itself cloud-only (nothing on disk); a
                        // mix stays plain, the cheap-and-correct v1.
                        let aggregateDataless = includingCloudOnly
                            && tail.allSatisfy { $0.allocatedSize == 0 }
                        cells.append(TreemapCell(
                            nodeID: node.id,
                            rect: aggregateRect,
                            rgb: aggregateRGB,
                            surface: aggregateSurface,
                            isDirectory: true,
                            aggregate: TreemapCell.AggregateInfo(
                                itemCount: itemCount,
                                totalSize: tail.reduce(Int64(0)) {
                                    $0 + $1.displayWeight(includingCloudOnly: includingCloudOnly)
                                }
                            ),
                            isDataless: aggregateDataless
                        ))
                    }
                    continue
                }
            }

            let isFreeSpace = node.id == freeSpaceNode?.id
            let isHiddenSpace = node.id == hiddenSpaceNode?.id
            var rgb: SIMD3<Float>
            if isFreeSpace {
                rgb = Self.freeSpaceRGB
            } else if isHiddenSpace {
                rgb = Self.hiddenSpaceRGB
            } else {
                rgb = baseRGB(for: node, colorMode: colorMode, catalog: catalog, palette: palette)
            }
            // Plain directories never match a highlight (they are neither a
            // stats kind nor a countable age node), so undivided-directory
            // cells always dim — even when they contain matching files too
            // deep to lay out.
            if let highlight, !matches(node, highlight: highlight, colorMode: colorMode, catalog: catalog) {
                rgb = dimmedRGB(rgb)
            }
            // Hatch a cell whose weight is entirely cloud-only: a dataless
            // file, or an undivided directory holding nothing but cloud bytes.
            let isDataless = includingCloudOnly
                && (node.isDataless
                    || (node.isDirectory && node.allocatedSize == 0 && node.cloudOnlyLogicalSize > 0))
            cells.append(TreemapCell(
                nodeID: node.id,
                rect: rect,
                rgb: rgb,
                surface: surface,
                isDirectory: node.isDirectory,
                isFreeSpace: isFreeSpace,
                isHiddenSpace: isHiddenSpace,
                isDataless: isDataless
            ))

            if !node.isDirectory {
                // Position the label inside the visible part of the cell.
                let visiblePart = rect.intersection(visibleBounds)
                if visiblePart.width >= labelMinCellWidth,
                   visiblePart.height >= labelMinCellHeight,
                   visiblePart.width * visiblePart.height >= labelMinCellArea {
                    labels.append(CellLabel(id: node.id, text: node.name, rect: visiblePart))
                }
            }
        }

        return TreemapScene(
            rootID: rootID, size: size, viewport: viewport,
            renderBounds: renderBounds, cells: cells, labels: labels,
            expandedAggregateIDs: expandedAggregateIDs,
            freeSpaceNode: freeSpaceNode,
            hiddenSpaceNode: hiddenSpaceNode,
            includingCloudOnly: includingCloudOnly
        )
    }

    /// A node's full-color cell fill under a color mode: kind palette color,
    /// or its age bucket's ramp color. Plain directories keep their neutral
    /// fill in both modes (a folder's own mtime says little about its
    /// contents).
    private nonisolated static func baseRGB(
        for node: FileNodeRecord,
        colorMode: TreemapColorMode,
        catalog: FileKindCatalog,
        palette: VizPalette
    ) -> SIMD3<Float> {
        switch colorMode {
        case .kind:
            return catalog.rgb(for: node)
        case .age(let referenceDate):
            guard FileKindClassifier.isLeafLike(node) else {
                return FileKindCatalog.directoryRGB
            }
            return palette.ageRGB(AgeBucket.bucket(for: node.lastModified, reference: referenceDate))
        }
    }

    /// Whether a node stays at full color under an active highlight. An age
    /// bucket highlight needs the `.age` color mode's reference date; with
    /// any other mode it matches nothing.
    private nonisolated static func matches(
        _ node: FileNodeRecord,
        highlight: TreemapHighlight,
        colorMode: TreemapColorMode,
        catalog: FileKindCatalog
    ) -> Bool {
        switch highlight {
        case .kind(let kindID):
            return FileKindClassifier.kindID(for: node, mode: catalog.mode) == kindID
        case .ageBucket(let bucket):
            guard case .age(let referenceDate) = colorMode,
                  FileKindClassifier.isLeafLike(node) else { return false }
            return AgeBucket.bucket(for: node.lastModified, reference: referenceDate) == bucket
        case .nodes(let ids):
            return ids.contains(node.id)
        }
    }

    private nonisolated static func makeFreeSpaceNode(
        rootID: String,
        root: FileNodeRecord,
        bytes: Int64?
    ) -> FileNodeRecord? {
        makeSyntheticSpaceNode(
            rootID: rootID,
            root: root,
            bytes: bytes,
            idSuffix: freeSpaceNodeSuffix,
            pathComponent: "__free-space__",
            name: NSLocalizedString("Free Space", comment: "Synthetic treemap node for a volume's free space")
        )
    }

    private nonisolated static func makeHiddenSpaceNode(
        rootID: String,
        root: FileNodeRecord,
        bytes: Int64?
    ) -> FileNodeRecord? {
        makeSyntheticSpaceNode(
            rootID: rootID,
            root: root,
            bytes: bytes,
            idSuffix: hiddenSpaceNodeSuffix,
            pathComponent: "__hidden-space__",
            name: NSLocalizedString("Hidden Space", comment: "Synthetic treemap node for a volume's hidden space")
        )
    }

    private nonisolated static func makeSyntheticSpaceNode(
        rootID: String,
        root: FileNodeRecord,
        bytes: Int64?,
        idSuffix: String,
        pathComponent: String,
        name: String
    ) -> FileNodeRecord? {
        guard let bytes, bytes > 0 else { return nil }
        return FileNodeRecord(
            id: rootID + idSuffix,
            url: root.url.appending(path: pathComponent),
            name: name,
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: bytes,
            logicalSize: bytes,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: true,
            isAutoSummarized: false
        )
    }

    /// Orders a directory's laid-out siblings (its filtered children plus any
    /// synthetic root blocks). Squarify wants weights descending, and with
    /// cloud-only weighting on the store's `allocatedSize` order is wrong —
    /// a mostly-dataless cloud root has nearly every child at zero on-disk
    /// bytes, so sort by `displayWeight` instead. With the flag off this stays
    /// byte-identical to before: the store order is preserved, and synthetic
    /// blocks fall back to the store's own `sortedChildren`.
    nonisolated static func layoutSiblings(
        _ children: [FileNodeRecord],
        synthetic: [FileNodeRecord],
        includingCloudOnly: Bool
    ) -> [FileNodeRecord] {
        if includingCloudOnly {
            return (children + synthetic).sorted { lhs, rhs in
                let lw = lhs.displayWeight(includingCloudOnly: true)
                let rw = rhs.displayWeight(includingCloudOnly: true)
                if lw == rw {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lw > rw
            }
        }
        if synthetic.isEmpty { return children }
        return FileTreeStore.sortedChildren(children + synthetic)
    }

    struct ChildLayout {
        /// Rects for the first `keptCount` children, in order.
        let rects: ArraySlice<CGRect>
        let keptCount: Int
        /// Rect covering the merged tail of small children, if any.
        let aggregateRect: CGRect?
    }

    /// Lays out a directory's children inside `rect`, merging the tail of
    /// children too small to see into a single trailing aggregate rect.
    /// Children must be sorted by size descending (FileTreeStore order).
    nonisolated static func layoutChildren(
        _ children: [FileNodeRecord],
        in rect: CGRect,
        includingCloudOnly: Bool = false,
        disableAggregation: Bool = false
    ) -> ChildLayout {
        func weight(_ node: FileNodeRecord) -> Int64 {
            node.displayWeight(includingCloudOnly: includingCloudOnly)
        }
        let totalSize = children.reduce(Int64(0)) { $0 + weight($1) }
        var keptCount = children.count
        if !disableAggregation, minChildCellArea > 0, totalSize > 0 {
            let areaPerByte = Double(rect.width * rect.height) / Double(totalSize)
            while keptCount > 0,
                  Double(weight(children[keptCount - 1])) * areaPerByte
                    < Double(minChildCellArea) {
                keptCount -= 1
            }
        }

        // Merging fewer than two children would just recolor one cell.
        if children.count - keptCount < 2 {
            let rects = TreemapLayout.squarify(
                weights: children.map { Double(weight($0)) },
                in: rect
            )
            return ChildLayout(rects: rects[...], keptCount: children.count, aggregateRect: nil)
        }

        let tailSize = children[keptCount...].reduce(Int64(0)) { $0 + weight($1) }
        var weights = children[..<keptCount].map { Double(weight($0)) }
        weights.append(Double(tailSize))
        let rects = TreemapLayout.squarify(weights: weights, in: rect)
        return ChildLayout(
            rects: rects[..<keptCount],
            keptCount: keptCount,
            aggregateRect: rects[keptCount]
        )
    }

    /// Whether the rendered region still covers everything `viewport` shows
    /// at full crispness — true only for pure pans that stay inside the
    /// overscan margin. Such viewport changes need no re-render.
    nonisolated func covers(_ viewport: TreemapViewport, viewSize: CGSize) -> Bool {
        guard self.viewport.scale == viewport.scale, size == viewSize else { return false }
        let renderedCanvasRect = renderBounds.offsetBy(
            dx: self.viewport.origin.x,
            dy: self.viewport.origin.y
        )
        // Half-point tolerance absorbs float fuzz from clamping math.
        let visible = viewport.visibleCanvasRect(viewSize: viewSize).insetBy(dx: 0.5, dy: 0.5)
        return renderedCanvasRect.contains(visible)
    }

    /// The cell containing `point`, if any.
    nonisolated func cell(at point: CGPoint) -> TreemapCell? {
        guard let candidates = cellGrid.candidateIndices(at: point) else {
            // Outside the indexed bounds (or a degenerate grid): cells can
            // overhang the render bounds, so fall back to the full scan.
            return cells.first { $0.rect.contains(point) }
        }
        for index in candidates where cells[Int(index)].rect.contains(point) {
            return cells[Int(index)]
        }
        return nil
    }

    /// The on-screen rect of an arbitrary node (not just rendered leaves),
    /// recomputed by re-running the layout along the path from the root.
    nonisolated func rect(forNodeID nodeID: String, in store: FileTreeStore) -> CGRect? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let fullChain = store.path(to: nodeID)
        guard let startIndex = fullChain.firstIndex(where: { $0.id == rootID }) else { return nil }
        let chain = Array(fullChain[startIndex...])

        var rect = CGRect(
            x: -viewport.origin.x,
            y: -viewport.origin.y,
            width: size.width * viewport.scale,
            height: size.height * viewport.scale
        )
        for (parent, child) in zip(chain, chain.dropFirst()) {
            let filtered = store.children(of: parent.id)
                .filter { $0.displayWeight(includingCloudOnly: includingCloudOnly) > 0 }
            // Mirror the render path exactly: the synthetic free/hidden-space
            // nodes participate in the root layout, and cloud-only weighting
            // reorders siblings — both shift every sibling's rect.
            let syntheticNodes = parent.id == rootID
                ? [freeSpaceNode, hiddenSpaceNode].compactMap { $0 } : []
            let children = Self.layoutSiblings(
                filtered, synthetic: syntheticNodes, includingCloudOnly: includingCloudOnly
            )
            guard let childIndex = children.firstIndex(where: { $0.id == child.id }) else {
                return nil
            }
            let layout = Self.layoutChildren(
                children,
                in: rect,
                includingCloudOnly: includingCloudOnly,
                disableAggregation: expandedAggregateIDs.contains(parent.id)
            )
            if childIndex < layout.keptCount {
                rect = layout.rects[childIndex]
            } else if let aggregateRect = layout.aggregateRect {
                // The node was merged into the "smaller items" cell; the best
                // rect we can offer is the aggregate itself.
                return aggregateRect
            } else {
                return nil
            }
        }
        return rect
    }
}


/// Uniform-bucket spatial index over a scene's cells. Cells tile the canvas
/// without overlap, so a bucket holds only the handful of cells that
/// intersect it and lookup is a few rect tests instead of a scan over the
/// whole cell list.
nonisolated struct CellGrid: Sendable {
    private let boundsOrigin: CGPoint
    private let bucketWidth: CGFloat
    private let bucketHeight: CGFloat
    private let columns: Int
    private let rows: Int
    private let buckets: [[Int32]]

    nonisolated init(cells: [TreemapCell], bounds: CGRect) {
        guard !cells.isEmpty, bounds.width >= 1, bounds.height >= 1 else {
            boundsOrigin = bounds.origin
            bucketWidth = max(bounds.width, 1)
            bucketHeight = max(bounds.height, 1)
            columns = 0
            rows = 0
            buckets = []
            return
        }

        // Aim for a handful of cells per bucket; the exact figure barely
        // matters because tiling bounds the entries per bucket.
        let targetBucketCount = min(4_096, max(1, cells.count / 4))
        let aspect = bounds.width / bounds.height
        let columnCount = max(1, Int((CGFloat(targetBucketCount) * aspect).squareRoot().rounded()))
        let rowCount = max(1, (targetBucketCount + columnCount - 1) / columnCount)

        boundsOrigin = bounds.origin
        bucketWidth = bounds.width / CGFloat(columnCount)
        bucketHeight = bounds.height / CGFloat(rowCount)
        columns = columnCount
        rows = rowCount

        var filledBuckets = [[Int32]](repeating: [], count: columnCount * rowCount)
        for (index, cell) in cells.enumerated() {
            let rect = cell.rect.intersection(bounds)
            guard !rect.isEmpty else { continue }
            let minColumn = max(0, Int((rect.minX - bounds.minX) / bucketWidth))
            let maxColumn = min(columnCount - 1, Int((rect.maxX - bounds.minX) / bucketWidth))
            let minRow = max(0, Int((rect.minY - bounds.minY) / bucketHeight))
            let maxRow = min(rowCount - 1, Int((rect.maxY - bounds.minY) / bucketHeight))
            guard minColumn <= maxColumn, minRow <= maxRow else { continue }
            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    filledBuckets[row * columnCount + column].append(Int32(index))
                }
            }
        }
        buckets = filledBuckets
    }

    /// Cell indices whose rects intersect the bucket containing `point`, or
    /// nil when the point lies outside the indexed bounds (or the grid is
    /// degenerate) and the caller should fall back to a full scan.
    nonisolated func candidateIndices(at point: CGPoint) -> [Int32]? {
        guard columns > 0, rows > 0 else { return nil }
        let column = Int((point.x - boundsOrigin.x) / bucketWidth)
        let row = Int((point.y - boundsOrigin.y) / bucketHeight)
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
        return buckets[row * columns + column]
    }
}
