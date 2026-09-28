//
//  Exports.swift
//  NeodiskWebEngine
//
//  The C ABI the website's engine.js drives. Bulk data crosses through
//  shared linear-memory buffers (pointers exported below); calls are per
//  frame / per layout, never per node. See engine.js for the JS-side
//  contract (buffer layouts are documented there as well).
//

import TreemapKit
import SunburstCore

// MARK: - Scratch

nonisolated(unsafe) let scratch = UnsafeMutablePointer<Double>.allocate(capacity: 256)
nonisolated(unsafe) let paletteTable = UnsafeMutablePointer<Float>.allocate(capacity: 3 * 64)

@_expose(wasm, "nd_version")
@_cdecl("nd_version")
public func ndVersion() -> Int32 { 1 }

/// A general-purpose Float64 scratch buffer (256 slots) for small results.
@_expose(wasm, "nd_scratch_ptr")
@_cdecl("nd_scratch_ptr")
public func ndScratchPtr() -> UnsafeMutablePointer<Double> { scratch }

// MARK: - Tree upload

/// Sizes the tree columns for `count` nodes (reallocating when it grows —
/// re-read every column pointer afterwards).
@_expose(wasm, "nd_tree_reset")
@_cdecl("nd_tree_reset")
public func ndTreeReset(_ count: Int32) -> Int32 {
    Tree.reserve(Int(max(count, 0)))
    return Int32(Tree.capacity)
}

@_expose(wasm, "nd_tree_parent_ptr") @_cdecl("nd_tree_parent_ptr")
public func ndTreeParentPtr() -> UnsafeMutablePointer<Int32> { Tree.parent }
@_expose(wasm, "nd_tree_first_child_ptr") @_cdecl("nd_tree_first_child_ptr")
public func ndTreeFirstChildPtr() -> UnsafeMutablePointer<Int32> { Tree.firstChild }
@_expose(wasm, "nd_tree_child_count_ptr") @_cdecl("nd_tree_child_count_ptr")
public func ndTreeChildCountPtr() -> UnsafeMutablePointer<Int32> { Tree.childCount }
@_expose(wasm, "nd_tree_weight_ptr") @_cdecl("nd_tree_weight_ptr")
public func ndTreeWeightPtr() -> UnsafeMutablePointer<Double> { Tree.weight }
@_expose(wasm, "nd_tree_alloc_ptr") @_cdecl("nd_tree_alloc_ptr")
public func ndTreeAllocPtr() -> UnsafeMutablePointer<Double> { Tree.alloc }
@_expose(wasm, "nd_tree_files_ptr") @_cdecl("nd_tree_files_ptr")
public func ndTreeFilesPtr() -> UnsafeMutablePointer<Double> { Tree.files }
@_expose(wasm, "nd_tree_flags_ptr") @_cdecl("nd_tree_flags_ptr")
public func ndTreeFlagsPtr() -> UnsafeMutablePointer<UInt32> { Tree.flags }
@_expose(wasm, "nd_tree_rgb_ptr") @_cdecl("nd_tree_rgb_ptr")
public func ndTreeRGBPtr() -> UnsafeMutablePointer<Float> { Tree.rgb }

// MARK: - Branch palette

/// Up to 64 RGB triples for table palettes (write before nd_palette_set).
@_expose(wasm, "nd_palette_table_ptr") @_cdecl("nd_palette_table_ptr")
public func ndPaletteTablePtr() -> UnsafeMutablePointer<Float> { paletteTable }

/// Selects SunburstCore's branch-hue strategy: kind 0 = continuous wheel
/// with the given saturation/brightness scales; kind 1 = table of
/// `tableCount` entries from nd_palette_table_ptr, in the order given (JS
/// hue-sorts quantized palettes, keeps ramps as-is — see palette.js).
@_expose(wasm, "nd_palette_set") @_cdecl("nd_palette_set")
public func ndPaletteSet(_ kind: Int32, _ saturationScale: Double, _ brightnessScale: Double, _ tableCount: Int32) {
    if kind == 1, tableCount > 0 {
        var entries: [SIMD3<Float>] = []
        for i in 0..<Int(min(tableCount, 64)) {
            entries.append(SIMD3(paletteTable[i * 3], paletteTable[i * 3 + 1], paletteTable[i * 3 + 2]))
        }
        Scene.palette = SunburstPalette.ramp(entries)
    } else {
        Scene.palette = SunburstPalette(branchHues: .wheel(saturationScale: saturationScale, brightnessScale: brightnessScale))
    }
}

/// Branch color of a token → scratch[0..2] (RGB) and scratch[3..5] (HSB).
/// role: 0 normal, 1 file, 2 aggregate, 3 free space, 4 hidden space.
@_expose(wasm, "nd_branch_color") @_cdecl("nd_branch_color")
public func ndBranchColor(_ midpoint: Double, _ depth: Int32, _ role: Int32) {
    let token = SunburstColorToken(midpoint: midpoint, depth: Int(depth), role: colorRole(role))
    let c = SunburstColorResolver.components(for: token, palette: Scene.palette)
    let rgb = SunburstColorResolver.rgb(from: c)
    scratch[0] = Double(rgb.x); scratch[1] = Double(rgb.y); scratch[2] = Double(rgb.z)
    scratch[3] = c.hue; scratch[4] = c.saturation; scratch[5] = c.brightness
}

func colorRole(_ raw: Int32) -> SunburstColorRole {
    switch raw {
    case 1: return .file
    case 2: return .aggregate
    case 3: return .freeSpace
    case 4: return .hiddenSpace
    default: return .normal
    }
}

func rawRole(_ role: SunburstColorRole) -> Double {
    switch role {
    case .normal: return 0
    case .file: return 1
    case .aggregate: return 2
    case .freeSpace: return 3
    case .hiddenSpace: return 4
    }
}

// MARK: - Treemap

nonisolated(unsafe) var cellOut: [Double] = []
nonisolated(unsafe) var labelOut: [Double] = []
nonisolated(unsafe) var pixels: [UInt8] = []
nonisolated(unsafe) var pixelsWidth: Int32 = 0
nonisolated(unsafe) var pixelsHeight: Int32 = 0

/// Builds the treemap scene (TreemapScene.build) for the subtree at `root`.
/// Returns the cell count; cells/labels/render bounds are then readable
/// through nd_tm_cells_ptr / nd_tm_labels_ptr / nd_tm_bounds.
@_expose(wasm, "nd_tm_build") @_cdecl("nd_tm_build")
public func ndTreemapBuild(
    _ root: Int32,
    _ width: Double, _ height: Double,
    _ viewportScale: Double, _ viewportX: Double, _ viewportY: Double,
    _ style: Int32, _ labelScale: Double,
    _ colorMode: Int32, _ hasHighlight: Int32,
    _ freeBytes: Double, _ hiddenBytes: Double,
    _ includingCloudOnly: Int32,
    _ bgR: Double, _ bgG: Double, _ bgB: Double
) -> Int32 {
    Scene.inputs = SceneInputs(
        root: root,
        size: CGSize(width: width, height: height),
        viewportScale: max(viewportScale, 1),
        viewportOrigin: CGPoint(x: viewportX, y: viewportY),
        style: style == 1 ? .flat : .cushion,
        labelScale: labelScale,
        colorMode: ColorMode(rawValue: colorMode) ?? .kind,
        hasHighlight: hasHighlight != 0,
        freeBytes: max(freeBytes, 0),
        hiddenBytes: max(hiddenBytes, 0),
        includingCloudOnly: includingCloudOnly != 0,
        background: SIMD3(Float(bgR), Float(bgG), Float(bgB))
    )
    Scene.build()

    let n = Scene.cells.count
    cellOut.removeAll(keepingCapacity: true)
    cellOut.reserveCapacity(n * 8)
    for i in 0..<n {
        let r = Scene.cells[i].rect
        cellOut.append(r.minX); cellOut.append(r.minY); cellOut.append(r.width); cellOut.append(r.height)
        cellOut.append(Double(Scene.cellNode[i]))
        cellOut.append(Double(Scene.cellFlags[i]))
        cellOut.append(Scene.cellAggCount[i])
        cellOut.append(Scene.cellAggSize[i])
    }
    labelOut.removeAll(keepingCapacity: true)
    for label in Scene.labels {
        labelOut.append(Double(label.node))
        labelOut.append(label.rect.minX); labelOut.append(label.rect.minY)
        labelOut.append(label.rect.width); labelOut.append(label.rect.height)
        labelOut.append(label.isHeader ? 1 : 0)
    }
    let b = Scene.renderBounds
    scratch[0] = b.minX; scratch[1] = b.minY; scratch[2] = b.width; scratch[3] = b.height
    return Int32(n)
}

/// Cells, 8 Float64 each: x, y, w, h, node (-2 free, -3 hidden), flags,
/// aggregate item count, aggregate total size.
@_expose(wasm, "nd_tm_cells_ptr") @_cdecl("nd_tm_cells_ptr")
public func ndTreemapCellsPtr() -> UnsafePointer<Double>? {
    cellOut.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "nd_tm_label_count") @_cdecl("nd_tm_label_count")
public func ndTreemapLabelCount() -> Int32 { Int32(Scene.labels.count) }

/// Labels, 6 Float64 each: node, x, y, w, h, isHeader.
@_expose(wasm, "nd_tm_labels_ptr") @_cdecl("nd_tm_labels_ptr")
public func ndTreemapLabelsPtr() -> UnsafePointer<Double>? {
    labelOut.withUnsafeBufferPointer { $0.baseAddress }
}

/// Render bounds of the last build → scratch[0..3] (x, y, w, h).
@_expose(wasm, "nd_tm_bounds") @_cdecl("nd_tm_bounds")
public func ndTreemapBounds() {
    let b = Scene.renderBounds
    scratch[0] = b.minX; scratch[1] = b.minY; scratch[2] = b.width; scratch[3] = b.height
}

/// Rasterizes the last scene with the real CushionTreemapRenderer /
/// FlatTreemapRenderer at `pixelScale` (device pixels per point) over the
/// render bounds. Transparent background (the pane shows through the gaps,
/// like the app). Returns 1 on success.
@_expose(wasm, "nd_tm_raster") @_cdecl("nd_tm_raster")
public func ndTreemapRaster(_ pixelScale: Double) -> Int32 {
    let bounds = Scene.renderBounds
    let result: (pixels: [UInt8], width: Int, height: Int)?
    if Scene.inputs.style == .flat {
        result = FlatTreemapRenderer.rasterizeRGBA(cells: Scene.cells, bounds: bounds, scale: pixelScale, background: nil)
    } else {
        result = CushionTreemapRenderer.rasterizeRGBA(cells: Scene.cells, bounds: bounds, scale: pixelScale, background: nil)
    }
    guard let result else {
        pixels = []
        pixelsWidth = 0
        pixelsHeight = 0
        return 0
    }
    pixels = result.pixels
    pixelsWidth = Int32(result.width)
    pixelsHeight = Int32(result.height)
    return 1
}

@_expose(wasm, "nd_tm_pixels_ptr") @_cdecl("nd_tm_pixels_ptr")
public func ndTreemapPixelsPtr() -> UnsafePointer<UInt8>? {
    pixels.withUnsafeBufferPointer { $0.baseAddress }
}
@_expose(wasm, "nd_tm_pixels_width") @_cdecl("nd_tm_pixels_width")
public func ndTreemapPixelsWidth() -> Int32 { pixelsWidth }
@_expose(wasm, "nd_tm_pixels_height") @_cdecl("nd_tm_pixels_height")
public func ndTreemapPixelsHeight() -> Int32 { pixelsHeight }

/// Deepest cell index at a point (scene coordinates), or -1.
/// `directoriesOnly` = TreemapScene.deepestDirectoryCell.
@_expose(wasm, "nd_tm_hit") @_cdecl("nd_tm_hit")
public func ndTreemapHit(_ x: Double, _ y: Double, _ directoriesOnly: Int32) -> Int32 {
    Int32(Scene.cell(at: CGPoint(x: x, y: y), directoriesOnly: directoriesOnly != 0))
}

/// A node's rect in the last scene (TreemapScene.rect(forNodeID:)) →
/// scratch[0..3]. Returns 0 when the node is not under the scene root.
@_expose(wasm, "nd_tm_rect_for") @_cdecl("nd_tm_rect_for")
public func ndTreemapRectFor(_ node: Int32) -> Int32 {
    guard let r = Scene.rect(forNode: node) else { return 0 }
    scratch[0] = r.minX; scratch[1] = r.minY; scratch[2] = r.width; scratch[3] = r.height
    return 1
}

// MARK: - Sunburst

nonisolated(unsafe) var sbSegments: [SunburstSegment] = []
nonisolated(unsafe) var sbOut: [Double] = []
nonisolated(unsafe) var sbArcs: [Double] = []
nonisolated(unsafe) var sbIndexByID: [String: Int32] = [:]
nonisolated(unsafe) var sbHitIndex = SunburstHitTestIndex(segments: [])
nonisolated(unsafe) var sbMetrics = SunburstRingMetrics(depthLimit: 1)

let segmentStride = 18

/// Lays out the sunburst (SunburstLayout.segments) rooted at `root`, with
/// the scan root's color coordinate system. Aggregation respects the
/// aggregateExpanded node flags. Returns the segment count.
@_expose(wasm, "nd_sb_layout") @_cdecl("nd_sb_layout")
public func ndSunburstLayout(
    _ root: Int32, _ depthLimit: Int32, _ minimumAngle: Double,
    _ freeBytes: Double, _ hiddenBytes: Double, _ includingCloudOnly: Int32
) -> Int32 {
    var expanded = Set<String>()
    for i in 0..<Tree.count where Tree.flags[i] & NodeFlags.aggregateExpanded != 0 {
        expanded.insert(idString(Int32(i)))
    }
    let limit = Int(max(depthLimit, 1))
    sbMetrics = SunburstRingMetrics(depthLimit: limit)
    let segments = (try? SunburstLayout.segments(
        in: WebTree(),
        rootID: idString(root),
        depthLimit: limit,
        minimumAngle: minimumAngle > 0 ? minimumAngle : .pi / 90,
        freeSpaceBytes: freeBytes > 0 ? Int64(freeBytes) : nil,
        hiddenSpaceBytes: hiddenBytes > 0 ? Int64(hiddenBytes) : nil,
        expandedAggregateIDs: expanded,
        includeCloudOnly: includingCloudOnly != 0,
        cancellationCheck: {}
    )) ?? []
    sbSegments = segments
    sbIndexByID = [:]
    sbOut.removeAll(keepingCapacity: true)
    sbOut.reserveCapacity(segments.count * segmentStride)
    for (i, s) in segments.enumerated() {
        sbIndexByID[s.id] = Int32(i)
        let node: Double
        if let id = s.nodeID, let n = parseID(id) {
            node = Double(n)
        } else if s.isFreeSpace {
            node = Double(freeSpaceIndex)
        } else if s.isHiddenSpace {
            node = Double(hiddenSpaceIndex)
        } else {
            node = -1
        }
        let parentFolder = s.parentFolderID.flatMap(parseID).map(Double.init) ?? -1
        let rgb = SunburstColorResolver.rgb(for: s.colorToken, palette: Scene.palette)
        let seam = SunburstArcGeometry.seamInsetAngles(
            startRadians: s.startAngle, endRadians: s.endAngle,
            innerRadius: s.innerRadius, outerRadius: s.outerRadius
        )
        sbOut.append(s.startAngle)                  // 0
        sbOut.append(s.endAngle)                    // 1
        sbOut.append(s.innerRadius)                 // 2
        sbOut.append(s.outerRadius)                 // 3
        sbOut.append(Double(s.depth))               // 4
        sbOut.append(node)                          // 5
        sbOut.append(rawRole(s.colorToken.role))    // 6
        sbOut.append(s.colorToken.midpoint)         // 7
        sbOut.append(Double(s.colorToken.depth))    // 8
        sbOut.append(Double(s.totalSize))           // 9
        sbOut.append(Double(s.itemCount))           // 10
        sbOut.append(s.isDataless ? 1 : 0)          // 11
        sbOut.append(parentFolder)                  // 12
        sbOut.append(Double(rgb.x))                 // 13
        sbOut.append(Double(rgb.y))                 // 14
        sbOut.append(Double(rgb.z))                 // 15
        sbOut.append(seam.start)                    // 16
        sbOut.append(seam.end)                      // 17
    }
    sbHitIndex = SunburstHitTestIndex(segments: segments)
    return Int32(segments.count)
}

@_expose(wasm, "nd_sb_segments_ptr") @_cdecl("nd_sb_segments_ptr")
public func ndSunburstSegmentsPtr() -> UnsafePointer<Double>? {
    sbOut.withUnsafeBufferPointer { $0.baseAddress }
}

/// Segment index under a point in a width×height chart box, or -1.
@_expose(wasm, "nd_sb_hit") @_cdecl("nd_sb_hit")
public func ndSunburstHit(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Int32 {
    guard let s = sbHitIndex.segment(atX: x, y: y, width: width, height: height) else { return -1 }
    return sbIndexByID[s.id] ?? -1
}

/// 1 when the point is inside the center disk (SunburstCenterHitTester).
@_expose(wasm, "nd_sb_center_hit") @_cdecl("nd_sb_center_hit")
public func ndSunburstCenterHit(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Int32 {
    SunburstCenterHitTester.contains(atX: x, y: y, width: width, height: height) ? 1 : 0
}

/// Zoom-transition geometry (SunburstZoomGeometry) for every segment of the
/// last layout toward `focus` at linear `progress` 0…1 → nd_sb_arcs_ptr,
/// 6 Float64 each: start, end, inner, outer, opacity, effectiveDepth.
@_expose(wasm, "nd_sb_zoom") @_cdecl("nd_sb_zoom")
public func ndSunburstZoom(_ focus: Int32, _ progress: Double) -> Int32 {
    guard focus >= 0, Int(focus) < sbSegments.count else { return 0 }
    let f = sbSegments[Int(focus)]
    sbArcs.removeAll(keepingCapacity: true)
    sbArcs.reserveCapacity(sbSegments.count * 6)
    for s in sbSegments {
        let arc = SunburstZoomGeometry.arc(for: s, focus: f, progress: progress, metrics: sbMetrics)
        sbArcs.append(arc.startRadians)
        sbArcs.append(arc.endRadians)
        sbArcs.append(arc.innerRadius)
        sbArcs.append(arc.outerRadius)
        sbArcs.append(SunburstZoomGeometry.opacity(for: s, focus: f, rawProgress: progress))
        sbArcs.append(SunburstZoomGeometry.effectiveDepth(for: s, focus: f, progress: progress))
    }
    return Int32(sbSegments.count)
}

@_expose(wasm, "nd_sb_arcs_ptr") @_cdecl("nd_sb_arcs_ptr")
public func ndSunburstArcsPtr() -> UnsafePointer<Double>? {
    sbArcs.withUnsafeBufferPointer { $0.baseAddress }
}

/// Ring radii of the last layout's metrics → scratch: for depth d in
/// 0..<min(depthLimit, 60): scratch[2d] = inner, scratch[2d+1] = drawn outer.
@_expose(wasm, "nd_sb_rings") @_cdecl("nd_sb_rings")
public func ndSunburstRings() -> Int32 {
    let n = min(sbMetrics.depthLimit, 60)
    for d in 0..<n {
        scratch[2 * d] = sbMetrics.innerRadius(depth: d)
        scratch[2 * d + 1] = sbMetrics.drawnOuterRadius(depth: d)
    }
    return Int32(n)
}

/// The scan-root color coordinate of a node (SunburstLayout.colorCoordinate)
/// → scratch[0..2] = start, span, depth. Returns 0 for unknown nodes.
@_expose(wasm, "nd_color_coordinate") @_cdecl("nd_color_coordinate")
public func ndColorCoordinate(_ node: Int32, _ includingCloudOnly: Int32) -> Int32 {
    guard let c = SunburstLayout.colorCoordinate(for: idString(node), in: WebTree(), includeCloudOnly: includingCloudOnly != 0) else {
        return 0
    }
    scratch[0] = c.start; scratch[1] = c.span; scratch[2] = Double(c.depth)
    return 1
}
