// Builds a subtree's renderable treemap cells: squarified layout plus cushion surface coefficients
// (van Wijk & van de Wetering, "Cushion Treemaps", 1999).

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SunburstCore
import TreemapKit
import NeodiskKit

/// What a cell's color means: file kind (default), age bucket against the scan date, or the sunburst's
/// branch hues (flat style on Largest / panel hidden) so the two views agree.
package enum TreemapColorMode: Equatable, Sendable {
    case kind
    case age(referenceDate: Date)
    case branch
}

/// A subset lit at full color while the rest dims; `.ageBucket` is valid only with the `.age` color mode.
package enum TreemapHighlight: Equatable, Sendable {
    case kind(String)
    case ageBucket(AgeBucket)
    case nodes(Set<String>)
}

package struct TreemapScene: Sendable {
    /// A name over a cell big enough for one: headers (flat) sit left in a container's strip, others center.
    package struct CellLabel: Sendable, Identifiable {
        package let id: String
        package let text: String
        package let rect: CGRect
        package var isHeader = false
    }

    package let rootID: String
    /// Draw/layout style the scene was built with; flat nests folder
    /// containers, cushion tiles leaves only.
    package let style: TreemapStyle
    package let size: CGSize
    package let viewport: TreemapViewport
    /// The rasterized region in view coordinates; a superset of the visible bounds when zoomed (overscan).
    package let renderBounds: CGRect
    package let cells: [TreemapCell]
    package let labels: [CellLabel]
    /// Directories whose "smaller items" aggregation is disabled because the
    /// user asked to see their contents individually.
    package let expandedAggregateIDs: Set<String>
    /// Synthetic node representing volume free space, laid out as an extra
    /// child of the root; nil when the feature is off or not a volume scan.
    package var freeSpaceNode: FileNodeRecord?
    /// Synthetic volume hidden-space node (purgeable, local snapshots, unseen files); nil when off or empty.
    package var hiddenSpaceNode: FileNodeRecord?
    /// Remembered so `rect(forNodeID:)` re-runs the layout with exactly the weights `build` used.
    package let includingCloudOnly: Bool
    /// Remembered for the same reason as `includingCloudOnly`: label gates and flat headers depend on it.
    package let labelScale: CGFloat
    /// Coarse spatial buckets over `cells` so hover hit-testing doesn't
    /// linear-scan tens of thousands of cells per mouse-move.
    private let cellGrid: CellGrid

    package nonisolated init(
        rootID: String,
        style: TreemapStyle = .cushion,
        size: CGSize,
        viewport: TreemapViewport,
        renderBounds: CGRect,
        cells: [TreemapCell],
        labels: [CellLabel],
        expandedAggregateIDs: Set<String>,
        freeSpaceNode: FileNodeRecord? = nil,
        hiddenSpaceNode: FileNodeRecord? = nil,
        includingCloudOnly: Bool = false,
        labelScale: CGFloat = 1
    ) {
        self.labelScale = labelScale
        self.rootID = rootID
        self.style = style
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

    /// The zoom root gets no ridge: one canvas-wide cushion darkens the edges without adding structure.
    package nonisolated static let rootRidgeHeight = 0.35
    package nonisolated static let ridgeFalloff = 0.85
    /// Rects smaller than this (in layout points) are not subdivided further;
    /// the directory is drawn as a single cell so the map has no holes.
    package nonisolated static let minSubdivisionArea: CGFloat = 12
    package nonisolated static let minSubdivisionSide: CGFloat = 2
    /// Children smaller than this merge into one "smaller items" cell. Flat merges more: its gaps and borders
    /// turn slivers the cushion can still shade into confetti.
    package nonisolated static let minChildCellArea: CGFloat = 64
    package nonisolated static let flatMinChildCellArea: CGFloat = 120

    /// Every re-layout must use the same threshold as `build`, or a merged node resolves to a phantom rect.
    package nonisolated static func minChildArea(for style: TreemapStyle) -> CGFloat {
        style == .flat ? flatMinChildCellArea : minChildCellArea
    }
    /// Undivided cells get a name once big enough. Gates are written for 100% text and scaled by the text
    /// scale (area by scale²), so bigger labels get bigger cells instead of overflowing.
    package nonisolated static func labelMinCellWidth(scale: CGFloat = 1) -> CGFloat { 80 * scale }
    package nonisolated static func labelMinCellHeight(scale: CGFloat = 1) -> CGFloat { 22 * scale }
    package nonisolated static func labelMinCellArea(scale: CGFloat = 1) -> CGFloat {
        4_000 * scale * scale
    }
    /// Extra margin rendered around the visible window (fraction of the view
    /// size per side) so pans show real pixels while the next render lands.
    package nonisolated static let overscanFraction: CGFloat = 0.3

    /// A directory big enough for a container gets a header strip and nests its children below it.
    package nonisolated static let flatContainerInset: CGFloat = 2
    package nonisolated static func flatHeaderHeight(scale: CGFloat = 1) -> CGFloat {
        (18 * scale).rounded()
    }
    package nonisolated static func flatMinContainerWidth(scale: CGFloat = 1) -> CGFloat { 52 * scale }
    /// Only the header grows with the text scale; scaling the whole threshold would thin nesting at large sizes.
    package nonisolated static func flatMinContainerHeight(scale: CGFloat = 1) -> CGFloat {
        flatHeaderHeight(scale: scale) + 28
    }
    /// Past this depth, nesting only shreds the map into tiny tiles; drilling re-roots, so nothing is hidden.
    package nonisolated static let flatMaxContainerDepth = 6
    /// Cheap pre-filter sized for ~4 characters; the exact rule runs where text is measured
    /// (`TreemapNSView.minUsefulTruncatedCharacters`).
    package nonisolated static func flatFolderLabelMinCellWidth(scale: CGFloat = 1) -> CGFloat {
        40 * scale
    }
    package nonisolated static func flatFolderLabelMinCellHeight(scale: CGFloat = 1) -> CGFloat {
        15 * scale
    }

    /// Nil when the rect is too small to nest; the caller then draws the directory as a plain cell.
    package nonisolated static func flatContentBounds(
        of rect: CGRect, scale: CGFloat = 1
    ) -> CGRect? {
        guard rect.width >= flatMinContainerWidth(scale: scale),
              rect.height >= flatMinContainerHeight(scale: scale) else { return nil }
        let header = flatHeaderHeight(scale: scale)
        var content = rect.insetBy(dx: flatContainerInset, dy: flatContainerInset)
        content.origin.y += header
        content.size.height -= header
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }
    /// Suffix of the synthetic free-space node's id (root id + suffix).
    private nonisolated static let freeSpaceNodeSuffix = "/__free-space__"
    /// Suffix of the synthetic hidden-space node's id (root id + suffix).
    private nonisolated static let hiddenSpaceNodeSuffix = "/__hidden-space__"

    /// Kind-highlight dimming: non-matching cells desaturate and darken so the highlighted kind pops.
    package nonisolated static let highlightDesaturation: Float = 0.7
    package nonisolated static let highlightDimBrightness: Float = 0.4

    /// The muted color a cell takes when a kind highlight is active and the
    /// cell doesn't match: desaturate toward gray, then darken.
    package nonisolated static func dimmedRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * highlightDesaturation
        return desaturated * highlightDimBrightness
    }

    /// Cloud-only cells recede a bit, gentler than a highlight dim. Applied to the resolved color, so every
    /// color mode inherits it.
    package nonisolated static let datalessDesaturation: Float = 0.45
    package nonisolated static let datalessDimBrightness: Float = 0.85

    package nonisolated static func datalessRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * datalessDesaturation
        return desaturated * datalessDimBrightness
    }

    package nonisolated static func build(
        store: FileTreeStore,
        rootID: String,
        style: TreemapStyle = .cushion,
        size: CGSize,
        catalog: FileKindCatalog,
        colorMode: TreemapColorMode = .kind,
        highlight: TreemapHighlight? = nil,
        expandedAggregateIDs: Set<String> = [],
        viewport: TreemapViewport = .identity,
        freeSpaceBytes: Int64? = nil,
        hiddenSpaceBytes: Int64? = nil,
        includingCloudOnly: Bool = false,
        palette: VizPalette = .standard,
        background: SIMD3<Float> = TreemapRasterTarget.backgroundRGB,
        labelScale: CGFloat = 1
    ) -> TreemapScene {
        var cells: [TreemapCell] = []
        var labels: [CellLabel] = []
        guard size.width >= 1, size.height >= 1, let root = store.node(id: rootID) else {
            return TreemapScene(
                rootID: rootID, style: style, size: size, viewport: viewport,
                renderBounds: CGRect(origin: .zero, size: size),
                cells: [], labels: [],
                expandedAggregateIDs: expandedAggregateIDs,
                includingCloudOnly: includingCloudOnly
            )
        }

        let freeSpaceNode = makeFreeSpaceNode(rootID: rootID, root: root, bytes: freeSpaceBytes)
        let hiddenSpaceNode = makeHiddenSpaceNode(rootID: rootID, root: root, bytes: hiddenSpaceBytes)

        // The virtual canvas is size × scale, positioned so geometry lands in view coordinates; subtrees outside
        // the visible window plus overscan are pruned.
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

        // Branch hue comes from the node's size interval anchored at the scan root (as in the sunburst), so
        // drilling never recolors a subtree.
        let rootDepth = max(store.path(to: rootID).count - 1, 0)
        let rootColor: (start: Double, span: Double)? = colorMode == .branch
            ? (rootID == store.root.id
                ? (start: 0, span: 1)
                : SunburstLayout.colorCoordinate(
                    for: rootID, in: store, includeCloudOnly: includingCloudOnly
                ).map { (start: $0.start, span: $0.span) } ?? (start: 0, span: 1))
            : nil

        // Flat fills composite once at flatFillOpacity over the background, baked so the raster stays opaque;
        // nesting reads through the depth ramp, since stacked composites turned to mud.
        var stack: [(node: FileNodeRecord, rect: CGRect, surface: CushionSurface, height: Double, isRoot: Bool, color: (start: Double, span: Double)?, depth: Int)] = [
            (root, rootRect, CushionSurface(), rootRidgeHeight, true, rootColor, 0)
        ]

        while let (node, rect, parentSurface, ridgeHeight, isRoot, color, depth) = stack.popLast() {
            guard rect.width > 0.5, rect.height > 0.5, rect.intersects(renderBounds) else { continue }

            var surface = parentSurface
            if style == .cushion, !isRoot {
                surface.addRidge(over: rect, height: ridgeHeight)
            }

            let subdividable = node.isDirectory
                && rect.width * rect.height >= minSubdivisionArea
                && min(rect.width, rect.height) >= minSubdivisionSide

            // nil (flat, too small to nest) falls through to the plain-cell path below.
            let childLayoutRect: CGRect?
            if !subdividable {
                childLayoutRect = nil
            } else if style == .flat, !isRoot {
                childLayoutRect = depth < flatMaxContainerDepth
                    ? flatContentBounds(of: rect, scale: labelScale) : nil
            } else {
                childLayoutRect = rect
            }

            if let childLayoutRect {
                let filtered = store.children(of: node.id)
                    .filter { $0.displayWeight(includingCloudOnly: includingCloudOnly) > 0 }
                let syntheticNodes = isRoot ? [freeSpaceNode, hiddenSpaceNode].compactMap { $0 } : []
                let children = layoutSiblings(
                    filtered, synthetic: syntheticNodes, includingCloudOnly: includingCloudOnly
                )
                if !children.isEmpty {
                    // The color interval divides among data children by weight in layout order; the synthetic free/hidden
                    // blocks advance nothing, keeping data on the full hue wheel.
                    var childColors: [(start: Double, span: Double)?]
                    if let color {
                        let dataTotal = children.reduce(Int64(0)) { total, child in
                            child.isSynthetic
                                ? total
                                : total + max(child.displayWeight(includingCloudOnly: includingCloudOnly), 1)
                        }
                        var colorCursor = color.start
                        childColors = children.map { child in
                            guard !child.isSynthetic else { return (start: colorCursor, span: 0) }
                            let unit = max(child.displayWeight(includingCloudOnly: includingCloudOnly), 1)
                            let span = color.span * (Double(unit) / Double(max(dataTotal, 1)))
                            defer { colorCursor += span }
                            return (start: colorCursor, span: span)
                        }
                    } else {
                        childColors = Array(repeating: nil, count: children.count)
                    }
                    if style == .flat, !isRoot {
                        // Emitted before the children so the flat renderer's in-order pass resolves the overdraw.
                        let swatchRGB = resolvedRGB(
                            for: node, colorMode: colorMode, catalog: catalog,
                            palette: palette, color: color,
                            // Status-bar branch swatches use the calm structural tint in both styles.
                            globalDepth: rootDepth + depth, style: .flat, store: store
                        )
                        var rgb = resolvedRGB(
                            for: node, colorMode: colorMode, catalog: catalog,
                            palette: palette, color: color,
                            globalDepth: rootDepth + depth, style: style, store: store
                        )
                        if let highlight,
                           !matches(node, highlight: highlight, colorMode: colorMode, catalog: catalog) {
                            rgb = dimmedRGB(rgb)
                        }
                        let isDataless = includingCloudOnly
                            && node.allocatedSize == 0 && node.cloudOnlyLogicalSize > 0
                        if isDataless { rgb = datalessRGB(rgb) }
                        if colorMode != .branch { rgb = flatDepthRamp(rgb, depth: rootDepth + depth) }
                        rgb = flatComposite(rgb, over: background)
                        cells.append(TreemapCell(
                            nodeID: node.id,
                            rect: rect,
                            rgb: rgb,
                            swatchRGB: swatchRGB,
                            surface: surface,
                            isDirectory: true,
                            isContainer: true,
                            isDataless: isDataless
                        ))
                        let headerRect = CGRect(
                            x: rect.minX + flatContainerInset + 4,
                            y: rect.minY + flatContainerInset + 1,
                            width: rect.width - 2 * (flatContainerInset + 4),
                            height: flatHeaderHeight(scale: labelScale) - 4
                        ).intersection(visibleBounds)
                        // The view drops the name if the strip is too narrow for a useful (≥4-character) truncation.
                        if !headerRect.isEmpty {
                            labels.append(CellLabel(
                                id: node.id, text: node.name, rect: headerRect, isHeader: true
                            ))
                        }
                    }
                    let childHeight = isRoot ? ridgeHeight : ridgeHeight * ridgeFalloff
                    let layout = layoutChildren(
                        children,
                        in: childLayoutRect,
                        includingCloudOnly: includingCloudOnly,
                        disableAggregation: expandedAggregateIDs.contains(node.id),
                        minChildArea: minChildArea(for: style)
                    )

                    for (index, (child, childRect)) in zip(children[..<layout.keptCount], layout.rects).enumerated() {
                        stack.append((
                            child, childRect, surface, childHeight, false,
                            childColors[index],
                            depth + 1
                        ))
                    }

                    if let aggregateRect = layout.aggregateRect,
                       aggregateRect.width > 0.5, aggregateRect.height > 0.5 {
                        let tail = children[layout.keptCount...]
                        var aggregateSurface = surface
                        if style == .cushion {
                            aggregateSurface.addRidge(over: aggregateRect, height: childHeight)
                        }
                        let itemCount = tail.reduce(0) {
                            $0 + ($1.isDirectory ? max($1.descendantFileCount, 1) : 1)
                        }
                        // With a highlight, an aggregate stays lit only if a directly merged node matches. Branch mode colors a
                        // folder's tail from the end of its interval; only the scan root's merge stays neutral gray.
                        var aggregateRGB: SIMD3<Float>
                        if colorMode == .branch {
                            if let color, node.id != store.root.id {
                                let tailSpan = childColors[layout.keptCount...]
                                    .reduce(0.0) { $0 + ($1?.span ?? 0) }
                                let tailStart = childColors[layout.keptCount]?.start
                                    ?? (color.start + color.span - tailSpan)
                                aggregateRGB = midpointRGB(
                                    midpoint: tailStart + tailSpan / 2,
                                    depth: rootDepth + depth + 1,
                                    role: .normal, style: style, palette: palette
                                )
                            } else {
                                aggregateRGB = SunburstColorResolver.rgb(
                                    for: SunburstColorToken(midpoint: 0, depth: 0, role: .aggregate),
                                    palette: palette.sunburst
                                )
                            }
                        } else {
                            aggregateRGB = FileKindCatalog.otherRGB
                        }
                        if let highlight {
                            let lit = tail.contains {
                                matches($0, highlight: highlight, colorMode: colorMode, catalog: catalog)
                            }
                            if !lit { aggregateRGB = dimmedRGB(aggregateRGB) }
                        }
                        // Hatch only when every merged node is cloud-only; a mix stays plain.
                        let aggregateDataless = includingCloudOnly
                            && tail.allSatisfy { $0.allocatedSize == 0 }
                        if aggregateDataless { aggregateRGB = datalessRGB(aggregateRGB) }
                        if style == .flat {
                            if colorMode != .branch {
                                aggregateRGB = flatDepthRamp(aggregateRGB, depth: rootDepth + depth + 1)
                            }
                            aggregateRGB = flatComposite(aggregateRGB, over: background)
                        }
                        cells.append(TreemapCell(
                            nodeID: node.id,
                            rect: aggregateRect,
                            rgb: aggregateRGB,
                            // Preserve the existing status-bar contract for
                            // pooled items, independent of branch coloring.
                            swatchRGB: FileKindCatalog.otherRGB,
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
            let swatchRGB: SIMD3<Float>
            if isFreeSpace {
                swatchRGB = SyntheticSpaceColors.freeSpaceRGB
            } else if isHiddenSpace {
                swatchRGB = SyntheticSpaceColors.hiddenSpaceRGB
            } else {
                swatchRGB = resolvedRGB(
                    for: node, colorMode: colorMode, catalog: catalog,
                    palette: palette, color: color,
                    globalDepth: rootDepth + depth, style: .flat, store: store
                )
            }
            var rgb: SIMD3<Float>
            if isFreeSpace || isHiddenSpace {
                rgb = swatchRGB
            } else {
                rgb = resolvedRGB(
                    for: node, colorMode: colorMode, catalog: catalog,
                    palette: palette, color: color,
                    globalDepth: rootDepth + depth, style: style, store: store
                )
            }
            // Plain directories never match a highlight, so undivided directory cells always dim.
            if let highlight, !matches(node, highlight: highlight, colorMode: colorMode, catalog: catalog) {
                rgb = dimmedRGB(rgb)
            }
            // Hatch a cell whose weight is entirely cloud-only: a dataless
            // file, or an undivided directory holding nothing but cloud bytes.
            let isDataless = includingCloudOnly
                && (node.isDataless
                    || (node.isDirectory && node.allocatedSize == 0 && node.cloudOnlyLogicalSize > 0))
            if isDataless { rgb = datalessRGB(rgb) }
            if style == .flat {
                if colorMode != .branch { rgb = flatDepthRamp(rgb, depth: rootDepth + depth) }
                rgb = flatComposite(rgb, over: background)
            }
            cells.append(TreemapCell(
                nodeID: node.id,
                rect: rect,
                rgb: rgb,
                swatchRGB: swatchRGB,
                surface: surface,
                isDirectory: node.isDirectory,
                isFreeSpace: isFreeSpace,
                isHiddenSpace: isHiddenSpace,
                isDataless: isDataless
            ))

            // Files share one label gate in both styles; flat undivided folders use the smaller folder gate, and
            // undivided cushion directories read like files. Gates are pre-filters; the view drops useless labels.
            let visiblePart = rect.intersection(visibleBounds)
            if style == .flat, node.isDirectory {
                if visiblePart.width >= flatFolderLabelMinCellWidth(scale: labelScale),
                   visiblePart.height >= flatFolderLabelMinCellHeight(scale: labelScale) {
                    labels.append(CellLabel(id: node.id, text: node.name, rect: visiblePart))
                }
            } else if visiblePart.width >= labelMinCellWidth(scale: labelScale),
                      visiblePart.height >= labelMinCellHeight(scale: labelScale),
                      visiblePart.width * visiblePart.height
                        >= labelMinCellArea(scale: labelScale) {
                labels.append(CellLabel(id: node.id, text: node.name, rect: visiblePart))
            }
        }

        return TreemapScene(
            rootID: rootID, style: style, size: size, viewport: viewport,
            renderBounds: renderBounds, cells: cells, labels: labels,
            expandedAggregateIDs: expandedAggregateIDs,
            freeSpaceNode: freeSpaceNode,
            hiddenSpaceNode: hiddenSpaceNode,
            includingCloudOnly: includingCloudOnly,
            labelScale: labelScale
        )
    }

    /// Matches the sunburst's translucent arcs; drawn once per cell, never over an ancestor's fill.
    package nonisolated static let flatFillOpacity: Float = 0.75

    package nonisolated static func flatComposite(
        _ rgb: SIMD3<Float>,
        over backdrop: SIMD3<Float>
    ) -> SIMD3<Float> {
        rgb * flatFillOpacity + backdrop * (1 - flatFillOpacity)
    }

    /// Raw resolver colors read loud through the translucent composite; loose root files dim instead.
    package nonisolated static let flatBranchDesaturation: Float = 0.18
    package nonisolated static let flatRootFileDim: Float = 0.9

    /// Flat kind/age nesting cue: deeper cells desaturate and darken a step per level. Branch colors skip
    /// it (their resolver already has a depth term).
    package nonisolated static let flatDepthDesaturation: Float = 0.03
    package nonisolated static let flatDepthDim: Float = 0.035
    package nonisolated static let flatDepthLimit = 6

    package nonisolated static func flatDepthRamp(
        _ rgb: SIMD3<Float>,
        depth: Int
    ) -> SIMD3<Float> {
        let tone = Float(min(max(depth - 1, 0), flatDepthLimit))
        guard tone > 0 else { return rgb }
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * (flatDepthDesaturation * tone)
        return desaturated * (1 - flatDepthDim * tone)
    }

    /// Plain directories stay neutral in kind/age modes (a folder's mtime says little); in branch mode
    /// `color` is the global size interval and `globalDepth` counts levels below the scan root.
    private nonisolated static func resolvedRGB(
        for node: FileNodeRecord,
        colorMode: TreemapColorMode,
        catalog: FileKindCatalog,
        palette: VizPalette,
        color: (start: Double, span: Double)?,
        globalDepth: Int,
        style: TreemapStyle,
        store: FileTreeStore
    ) -> SIMD3<Float> {
        switch colorMode {
        case .kind:
            return catalog.rgb(for: node)
        case .age(let referenceDate):
            guard FileKindClassifier.isLeafLike(node) else {
                return FileKindCatalog.directoryRGB
            }
            return palette.ageRGB(AgeBucket.bucket(for: node.lastModified, reference: referenceDate))
        case .branch:
            // Files use the folder formula: gray files would wash out a treemap that is mostly file tiles. Loose
            // scan-root files go gray, or they would bury the folders that have structure.
            let depth = max(globalDepth, 1)
            var role = SunburstColorRole.normal
            if depth <= 1, !SunburstLayout.isSunburstFolder(node, in: store) {
                role = .file
            }
            let midpoint = color.map { $0.start + $0.span / 2 } ?? 0.5
            return midpointRGB(
                midpoint: midpoint, depth: depth, role: role,
                style: style, palette: palette
            )
        }
    }

    /// Flat pulls lightly toward gray for its translucent composite; the cushion keeps the color as is.
    private nonisolated static func midpointRGB(
        midpoint: Double,
        depth: Int,
        role: SunburstColorRole,
        style: TreemapStyle,
        palette: VizPalette
    ) -> SIMD3<Float> {
        let token = SunburstColorToken(midpoint: midpoint, depth: depth, role: role)
        let rgb = SunburstColorResolver.rgb(for: token, palette: palette.sunburst)
        guard role == .normal else { return rgb * flatRootFileDim }
        guard style == .flat else { return rgb }
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        return rgb + (gray - rgb) * flatBranchDesaturation
    }

    /// Shared with the sunburst so both dim the same nodes. An age bucket matches only under `.age`.
    package nonisolated static func matches(
        _ node: FileNodeRecord,
        highlight: TreemapHighlight,
        colorMode: TreemapColorMode,
        catalog: FileKindCatalog
    ) -> Bool {
        switch highlight {
        case .kind(let kindID):
            return FileKindClassifier.kindID(for: node, mode: catalog.mode, rules: catalog.rules) == kindID
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
            name: AppStrings.localized("Free Space", comment: "Synthetic treemap node for a volume's free space")
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
            name: AppStrings.localized("Hidden Space", comment: "Synthetic treemap node for a volume's hidden space")
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

    /// Squarify wants weights descending; with cloud-only weighting a dataless root's store order is wrong,
    /// so sort by `displayWeight`. With the flag off the store order is kept as is.
    package nonisolated static func layoutSiblings(
        _ children: [FileNodeRecord],
        synthetic: [FileNodeRecord],
        includingCloudOnly: Bool
    ) -> [FileNodeRecord] {
        if includingCloudOnly {
            return (children + synthetic).sorted { lhs, rhs in
                let lw = lhs.displayWeight(includingCloudOnly: true)
                let rw = rhs.displayWeight(includingCloudOnly: true)
                if lw == rw {
                    return DisplayNameOrder.precedes(lhs.name, rhs.name)
                }
                return lw > rw
            }
        }
        if synthetic.isEmpty { return children }
        return FileTreeStore.sortedChildren(children + synthetic)
    }

    package struct ChildLayout {
        /// Rects for the first `keptCount` children, in order.
        package let rects: ArraySlice<CGRect>
        package let keptCount: Int
        /// Rect covering the merged tail of small children, if any.
        package let aggregateRect: CGRect?
    }

    /// Merges the tail of too-small children into one trailing aggregate rect. Children must be sorted
    /// by size descending.
    package nonisolated static func layoutChildren(
        _ children: [FileNodeRecord],
        in rect: CGRect,
        includingCloudOnly: Bool = false,
        disableAggregation: Bool = false,
        minChildArea: CGFloat = minChildCellArea
    ) -> ChildLayout {
        func weight(_ node: FileNodeRecord) -> Int64 {
            node.displayWeight(includingCloudOnly: includingCloudOnly)
        }
        let totalSize = children.reduce(Int64(0)) { $0 + weight($1) }
        var keptCount = children.count
        if !disableAggregation, minChildArea > 0, totalSize > 0 {
            let areaPerByte = Double(rect.width * rect.height) / Double(totalSize)
            while keptCount > 0,
                  Double(weight(children[keptCount - 1])) * areaPerByte
                    < Double(minChildArea) {
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

    /// True only for pure pans that stay inside the overscan margin; those need no re-render.
    package nonisolated func covers(_ viewport: TreemapViewport, viewSize: CGSize) -> Bool {
        guard self.viewport.scale == viewport.scale, size == viewSize else { return false }
        let renderedCanvasRect = renderBounds.offsetBy(
            dx: self.viewport.origin.x,
            dy: self.viewport.origin.y
        )
        // Half-point tolerance absorbs float fuzz from clamping math.
        let visible = viewport.visibleCanvasRect(viewSize: viewSize).insetBy(dx: 0.5, dy: 0.5)
        return renderedCanvasRect.contains(visible)
    }

    /// Flat cells overlap (parents emitted first), so the highest-index match is the deepest cell.
    package nonisolated func cell(at point: CGPoint) -> TreemapCell? {
        guard let candidates = cellGrid.candidateIndices(at: point) else {
            // Outside the indexed bounds (or a degenerate grid): cells can
            // overhang the render bounds, so fall back to the full scan.
            return cells.last { $0.rect.contains(point) }
        }
        var deepest: Int32?
        for index in candidates where cells[Int(index)].rect.contains(point) {
            if deepest == nil || index > deepest! { deepest = index }
        }
        return deepest.map { cells[Int($0)] }
    }

    /// Folder-backed: a container, undivided directory or aggregate. Flat pinch drilling targets this.
    package nonisolated func deepestDirectoryCell(at point: CGPoint) -> TreemapCell? {
        guard let candidates = cellGrid.candidateIndices(at: point) else {
            return cells.last { $0.isDirectory && $0.rect.contains(point) }
        }
        var deepest: Int32?
        for index in candidates {
            let cell = cells[Int(index)]
            guard cell.isDirectory, cell.rect.contains(point) else { continue }
            if deepest == nil || index > deepest! { deepest = index }
        }
        return deepest.map { cells[Int($0)] }
    }

    /// The on-screen rect of an arbitrary node (not just rendered leaves),
    /// recomputed by re-running the layout along the path from the root.
    package nonisolated func rect(forNodeID nodeID: String, in store: FileTreeStore) -> CGRect? {
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
        // `depth` counts levels below the scene root, exactly as `build`'s
        // traversal does for the parent being subdivided.
        for (depth, (parent, child)) in zip(chain, chain.dropFirst()).enumerated() {
            let filtered = store.children(of: parent.id)
                .filter { $0.displayWeight(includingCloudOnly: includingCloudOnly) > 0 }
            // Mirror the render path: synthetic nodes and cloud-only ordering both shift sibling rects.
            let syntheticNodes = parent.id == rootID
                ? [freeSpaceNode, hiddenSpaceNode].compactMap { $0 } : []
            let children = Self.layoutSiblings(
                filtered, synthetic: syntheticNodes, includingCloudOnly: includingCloudOnly
            )
            guard let childIndex = children.firstIndex(where: { $0.id == child.id }) else {
                return nil
            }
            var layoutRect = rect
            if style == .flat, parent.id != rootID {
                // Mirror the flat build: a container too small to nest, or past the depth cap, is the best rect on offer.
                guard depth < Self.flatMaxContainerDepth,
                      let content = Self.flatContentBounds(of: rect, scale: labelScale) else {
                    return rect
                }
                layoutRect = content
            }
            let layout = Self.layoutChildren(
                children,
                in: layoutRect,
                includingCloudOnly: includingCloudOnly,
                disableAggregation: expandedAggregateIDs.contains(parent.id),
                minChildArea: Self.minChildArea(for: style)
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


/// Uniform-bucket spatial index: lookup is a few rect tests instead of a scan over every cell.
package nonisolated struct CellGrid: Sendable {
    private let boundsOrigin: CGPoint
    private let bucketWidth: CGFloat
    private let bucketHeight: CGFloat
    private let columns: Int
    private let rows: Int
    private let buckets: [[Int32]]

    package nonisolated init(cells: [TreemapCell], bounds: CGRect) {
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

    /// Nil when the point is outside the indexed bounds; the caller falls back to a full scan.
    package nonisolated func candidateIndices(at point: CGPoint) -> [Int32]? {
        guard columns > 0, rows > 0 else { return nil }
        let column = Int((point.x - boundsOrigin.x) / bucketWidth)
        let row = Int((point.y - boundsOrigin.y) / bucketHeight)
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
        return buckets[row * columns + column]
    }
}
