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
import SunburstCore
import TreemapKit
import NeodiskKit

/// What a treemap cell's color means: the node's file kind (the default),
/// its modification-age bucket measured against the snapshot's scan date,
/// or — flat style on the Largest tab / with the statistics panel hidden —
/// the sunburst's branch hues, so the two structural views agree.
enum TreemapColorMode: Equatable, Sendable {
    case kind
    case age(referenceDate: Date)
    case branch
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
    /// A name drawn on top of a cell large enough to carry one. Header
    /// labels (flat style) sit left-aligned in a container's header strip;
    /// plain labels center inside a file cell.
    struct CellLabel: Sendable, Identifiable {
        let id: String
        let text: String
        let rect: CGRect
        var isHeader = false
    }

    let rootID: String
    /// Draw/layout style the scene was built with; flat nests folder
    /// containers, cushion tiles leaves only.
    let style: TreemapStyle
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
        style: TreemapStyle = .cushion,
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
    /// merged into a single "smaller items" cell per directory. The flat
    /// style merges more aggressively: its per-tile gap and border eat a
    /// larger share of a small tile, so slivers the cushion can still shade
    /// read as border-only confetti in flat.
    nonisolated static let minChildCellArea: CGFloat = 64
    nonisolated static let flatMinChildCellArea: CGFloat = 120
    /// Undivided cells — files, and cushion directories drawn as one solid
    /// tile (packages, summarized/inaccessible folders) — get their name
    /// drawn once their on-screen cell is big enough to carry it legibly;
    /// zooming in reveals more names as cells grow.
    nonisolated static let labelMinCellWidth: CGFloat = 80
    nonisolated static let labelMinCellHeight: CGFloat = 22
    nonisolated static let labelMinCellArea: CGFloat = 4_000
    /// Extra margin rendered around the visible window (fraction of the view
    /// size per side) so pans show real pixels while the next render lands.
    nonisolated static let overscanFraction: CGFloat = 0.3

    /// Flat nesting: a directory large enough for a
    /// container box draws a header strip and lays its children out in the
    /// inset region below it; smaller directories render as plain cells,
    /// which is the style's natural depth cutoff.
    nonisolated static let flatContainerInset: CGFloat = 2
    nonisolated static let flatHeaderHeight: CGFloat = 18
    nonisolated static let flatMinContainerWidth: CGFloat = 52
    nonisolated static let flatMinContainerHeight: CGFloat = 46
    /// Directories deeper than this many levels below the scene root render
    /// as plain cells even when large enough to nest: past a handful of
    /// levels the boxes-in-boxes framing stops informing and only shreds the
    /// map into tiny tiles. Drilling in re-roots the scene, so the cap never
    /// hides anything from navigation.
    nonisolated static let flatMaxContainerDepth = 6
    /// Undivided folders label far smaller than files (files share the
    /// cushion gates above — only genuinely big tiles carry a file name).
    /// These are a cheap pre-filter sized to where ~4 characters can fit;
    /// the exact keep-enough-characters rule runs where text is measured
    /// (`TreemapNSView.minUsefulTruncatedCharacters`).
    nonisolated static let flatFolderLabelMinCellWidth: CGFloat = 40
    nonisolated static let flatFolderLabelMinCellHeight: CGFloat = 15

    /// The region a flat container's children occupy, or nil when the rect
    /// is too small to nest — the caller then draws the directory as a
    /// plain cell.
    nonisolated static func flatContentBounds(of rect: CGRect) -> CGRect? {
        guard rect.width >= flatMinContainerWidth,
              rect.height >= flatMinContainerHeight else { return nil }
        var content = rect.insetBy(dx: flatContainerInset, dy: flatContainerInset)
        content.origin.y += flatHeaderHeight
        content.size.height -= flatHeaderHeight
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }
    /// Suffix of the synthetic free-space node's id (root id + suffix).
    private nonisolated static let freeSpaceNodeSuffix = "/__free-space__"
    /// Suffix of the synthetic hidden-space node's id (root id + suffix).
    private nonisolated static let hiddenSpaceNodeSuffix = "/__hidden-space__"

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

    /// Cloud-only cells: a gentler cousin of the highlight dim — nudged
    /// toward gray and slightly darkened, so dataless content visibly
    /// recedes next to on-disk files without going as mute as a dimmed
    /// non-match. Applied to the resolved color, so every color mode
    /// (kinds, age, highlights) inherits it; the raster hatch adds texture.
    nonisolated static let datalessDesaturation: Float = 0.45
    nonisolated static let datalessDimBrightness: Float = 0.85

    nonisolated static func datalessRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * datalessDesaturation
        return desaturated * datalessDimBrightness
    }

    nonisolated static func build(
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
        background: SIMD3<Float> = TreemapRasterTarget.backgroundRGB
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

        // Branch-color context (flat style): the hue family walks up to the
        // scan root even when the map is drilled in, matching
        // SunburstColorResolver.branchColor. A nil id at the scene root means
        // "each root child starts its own branch". Color depth counts levels
        // below the SCAN root (`rootDepth` offsets a drilled scene), so
        // drilling in never re-brightens a subtree — its colors stay put,
        // and the ramp's clamp keeps deep trees from going black.
        let rootDepth = max(store.path(to: rootID).count - 1, 0)
        let rootBranch: (id: String?, depth: Int)? = colorMode == .branch
            ? (rootID == store.root.id ? nil : SunburstLayout.topLevelBranchID(for: rootID, in: store), rootDepth - 1)
            : nil

        // Flat fills are "translucent": each cell's color composites once at
        // flatFillOpacity over the window background — the sunburst's
        // translucent-arc look, baked analytically so the raster stays
        // opaque memset runs. Nesting reads through the depth ramp instead
        // of stacking composites, which compounded toward mud. `depth`
        // counts levels below the scene root.
        var stack: [(node: FileNodeRecord, rect: CGRect, surface: CushionSurface, height: Double, isRoot: Bool, branch: (id: String?, depth: Int)?, depth: Int)] = [
            (root, rootRect, CushionSurface(), rootRidgeHeight, true, rootBranch, 0)
        ]

        while let (node, rect, parentSurface, ridgeHeight, isRoot, branch, depth) = stack.popLast() {
            guard rect.width > 0.5, rect.height > 0.5, rect.intersects(renderBounds) else { continue }

            var surface = parentSurface
            if style == .cushion, !isRoot {
                surface.addRidge(over: rect, height: ridgeHeight)
            }

            let subdividable = node.isDirectory
                && rect.width * rect.height >= minSubdivisionArea
                && min(rect.width, rect.height) >= minSubdivisionSide

            // Where this directory's children lay out: the rect itself, or —
            // flat style, non-root — the container's inset content region.
            // nil (flat, too small to nest) falls through to the plain-cell
            // path below, which is the flat style's natural depth cutoff.
            let childLayoutRect: CGRect?
            if !subdividable {
                childLayoutRect = nil
            } else if style == .flat, !isRoot {
                childLayoutRect = depth < flatMaxContainerDepth ? flatContentBounds(of: rect) : nil
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
                    if style == .flat, !isRoot {
                        // The container cell: full rect under its children,
                        // leaving the border frame and header strip visible.
                        // Emitted before the children so the flat renderer's
                        // in-order pass resolves the overdraw correctly.
                        var rgb = resolvedRGB(
                            for: node, colorMode: colorMode, catalog: catalog,
                            palette: palette, branch: branch, style: style, store: store
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
                            surface: surface,
                            isDirectory: true,
                            isContainer: true,
                            isDataless: isDataless
                        ))
                        let headerRect = CGRect(
                            x: rect.minX + flatContainerInset + 4,
                            y: rect.minY + flatContainerInset + 1,
                            width: rect.width - 2 * (flatContainerInset + 4),
                            height: flatHeaderHeight - 4
                        ).intersection(visibleBounds)
                        // Every container whose header strip shows emits a
                        // name candidate; the view drops it if the strip is
                        // too narrow for a useful (≥4-character) truncation.
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
                        minChildArea: style == .flat ? flatMinChildCellArea : minChildCellArea
                    )

                    for (child, childRect) in zip(children[..<layout.keptCount], layout.rects) {
                        stack.append((
                            child, childRect, surface, childHeight, false,
                            branch.map { (id: $0.id ?? child.id, depth: $0.depth + 1) },
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
                        // With a highlight active, an aggregate stays lit
                        // only when a directly merged node matches — the tail
                        // is already in hand, so this check is cheap. Matches
                        // hidden deeper inside merged subdirectories are not
                        // searched for; those aggregates dim.
                        // Branch mode: a folder's merged tail carries the
                        // folder's branch hue one level deeper, like the
                        // children it stands for — a gray cell per folder
                        // read as holes punched in the hue field. Only the
                        // scan root's own merge stays the sunburst's neutral
                        // aggregate gray: its tail spans many branches.
                        var aggregateRGB: SIMD3<Float>
                        if colorMode == .branch {
                            if let branch, let branchID = branch.id {
                                aggregateRGB = branchRGB(
                                    branchID: branchID, nodeID: node.id,
                                    depth: max(branch.depth + 1, 0),
                                    role: .normal, style: style, palette: palette
                                )
                            } else {
                                aggregateRGB = SunburstColorResolver.rgb(
                                    for: .single(id: node.id, role: .aggregate),
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
                        // Hatch the merged cell only when every node folded
                        // into it is itself cloud-only (nothing on disk); a
                        // mix stays plain, the cheap-and-correct v1.
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
                rgb = SyntheticSpaceColors.freeSpaceRGB
            } else if isHiddenSpace {
                rgb = SyntheticSpaceColors.hiddenSpaceRGB
            } else {
                rgb = resolvedRGB(
                    for: node, colorMode: colorMode, catalog: catalog,
                    palette: palette, branch: branch, style: style, store: store
                )
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
            if isDataless { rgb = datalessRGB(rgb) }
            if style == .flat {
                if colorMode != .branch { rgb = flatDepthRamp(rgb, depth: rootDepth + depth) }
                rgb = flatComposite(rgb, over: background)
            }
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

            // Position the label inside the visible part of the cell. Files
            // share one gate across both styles: only genuinely big tiles
            // carry a name (zooming in reveals more). Flat undivided folders
            // label at the smaller folder gate. Cushion directories reaching
            // this path are always undivided — packages, summarized and
            // inaccessible folders drawn as one solid cell — so they read
            // like files and label at the file gate; subdivided directories
            // never get here (their area belongs to their children). Gates
            // are pre-filters — the view still drops any label whose
            // truncation would keep too few characters to inform.
            let visiblePart = rect.intersection(visibleBounds)
            if style == .flat, node.isDirectory {
                if visiblePart.width >= flatFolderLabelMinCellWidth,
                   visiblePart.height >= flatFolderLabelMinCellHeight {
                    labels.append(CellLabel(id: node.id, text: node.name, rect: visiblePart))
                }
            } else if visiblePart.width >= labelMinCellWidth,
                      visiblePart.height >= labelMinCellHeight,
                      visiblePart.width * visiblePart.height >= labelMinCellArea {
                labels.append(CellLabel(id: node.id, text: node.name, rect: visiblePart))
            }
        }

        return TreemapScene(
            rootID: rootID, style: style, size: size, viewport: viewport,
            renderBounds: renderBounds, cells: cells, labels: labels,
            expandedAggregateIDs: expandedAggregateIDs,
            freeSpaceNode: freeSpaceNode,
            hiddenSpaceNode: hiddenSpaceNode,
            includingCloudOnly: includingCloudOnly
        )
    }

    /// Flat-style translucency, matching the sunburst's translucent-arc
    /// look (its fills draw at ~0.78 opacity): the resolved color drawn at
    /// this opacity over the window background — once per cell, never over
    /// an ancestor's fill (chained composites compounded toward mud).
    nonisolated static let flatFillOpacity: Float = 0.75

    nonisolated static func flatComposite(
        _ rgb: SIMD3<Float>,
        over backdrop: SIMD3<Float>
    ) -> SIMD3<Float> {
        rgb * flatFillOpacity + backdrop * (1 - flatFillOpacity)
    }

    /// Flat branch fills pull lightly toward gray: the translucent
    /// composite is part of the look, and raw resolver colors read loud
    /// through it. Loose scan-root files are already gray; they dim a
    /// touch instead so they recede rather than glow.
    nonisolated static let flatBranchDesaturation: Float = 0.18
    nonisolated static let flatRootFileDim: Float = 0.9

    /// Flat nesting cue for the kind/age modes: deeper cells desaturate and
    /// darken a step per level, clamped, so containment reads without
    /// stacked translucency. Branch colors skip this — their resolver
    /// already carries the same ramp in its depth term. Scene-root children
    /// (depth 1) stay at full color, like the sunburst's first ring.
    nonisolated static let flatDepthDesaturation: Float = 0.03
    nonisolated static let flatDepthDim: Float = 0.035
    nonisolated static let flatDepthLimit = 6

    nonisolated static func flatDepthRamp(
        _ rgb: SIMD3<Float>,
        depth: Int
    ) -> SIMD3<Float> {
        let tone = Float(min(max(depth - 1, 0), flatDepthLimit))
        guard tone > 0 else { return rgb }
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        let desaturated = rgb + (gray - rgb) * (flatDepthDesaturation * tone)
        return desaturated * (1 - flatDepthDim * tone)
    }

    /// A node's full-color cell fill under a color mode: kind palette color,
    /// age ramp, or the sunburst's branch hue (flat style). Plain directories
    /// keep their neutral fill in the kind/age modes (a folder's own mtime
    /// says little about its contents); in branch mode folders carry the hue
    /// and files go gray, exactly like the sunburst — `branch` is the
    /// traversal-carried (top-level branch id, depth) pair.
    private nonisolated static func resolvedRGB(
        for node: FileNodeRecord,
        colorMode: TreemapColorMode,
        catalog: FileKindCatalog,
        palette: VizPalette,
        branch: (id: String?, depth: Int)?,
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
            // Files share the folder formula (role .normal): branch hue and
            // depth ramp. The sunburst grays its files (thin outer arcs); a
            // treemap's area is mostly file tiles, so gray — or a heavily
            // muted tint — washes the whole map out. A loose file at the
            // scan root goes gray like the sunburst's files instead: it has
            // no hue family of its own, and a root full of vividly colored
            // loose files buries the smaller folders that actually have
            // structure worth spotting.
            var depth = max(branch?.depth ?? 0, 0)
            var role = SunburstColorRole.normal
            if depth == 0, !SunburstLayout.isSunburstFolder(node, in: store) {
                depth = 1
                role = .file
            }
            return branchRGB(
                branchID: branch?.id ?? node.id, nodeID: node.id,
                depth: depth, role: role, style: style, palette: palette
            )
        }
    }

    /// A branch-mode fill: the sunburst resolver's color for (branch, node,
    /// depth), adjusted per style. Flat keeps the resolver's per-node hue
    /// jitter and pulls lightly toward gray — its translucent composite is
    /// part of the look, and the jitter separates its bordered tiles. The
    /// cushion drops the per-node variance entirely (localID = branch id):
    /// its shading already separates neighbors, and jittered hues across
    /// shaded tiles read muddy — one clean hue per branch and depth.
    private nonisolated static func branchRGB(
        branchID: String,
        nodeID: String,
        depth: Int,
        role: SunburstColorRole,
        style: TreemapStyle,
        palette: VizPalette
    ) -> SIMD3<Float> {
        let token = SunburstColorToken(
            branchID: branchID,
            localID: style == .flat ? nodeID : branchID,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: role
        )
        let rgb = SunburstColorResolver.rgb(for: token, palette: palette.sunburst)
        guard role == .normal else { return rgb * flatRootFileDim }
        guard style == .flat else { return rgb }
        let gray = SIMD3<Float>(repeating: (rgb.x + rgb.y + rgb.z) / 3)
        return rgb + (gray - rgb) * flatBranchDesaturation
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

    /// The cell containing `point`, if any. Flat-style cells overlap
    /// (containers under their descendants) and the scene emits parents
    /// before children, so the highest-index match is the deepest cell —
    /// a container wins only on its visible frame and header strip. In the
    /// cushion style cells tile without overlap and the scan degenerates
    /// to the single match.
    nonisolated func cell(at point: CGPoint) -> TreemapCell? {
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

    /// The deepest folder-backed cell at `point`: a flat container, an
    /// undivided directory, or a "smaller items" aggregate (whose nodeID is
    /// the owning folder). Flat-style pinch drilling targets this, so a
    /// pinch over a file drills into the file's enclosing container.
    nonisolated func deepestDirectoryCell(at point: CGPoint) -> TreemapCell? {
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
            var layoutRect = rect
            if style == .flat, parent.id != rootID {
                // Mirror the flat build: children nest in the container's
                // content region. A container too small to nest rendered no
                // children, so the container itself is the best rect on offer
                // (same contract as the aggregate fallback below).
                guard let content = Self.flatContentBounds(of: rect) else { return rect }
                layoutRect = content
            }
            let layout = Self.layoutChildren(
                children,
                in: layoutRect,
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
