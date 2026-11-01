// Arcs are painted once per layout into a CPU raster off the main thread, with hover and selection drawn as
// Direct2D paths on top, so pointer movement never repaints thousands of arcs. Drill frames draw the moving arcs
// as paths and hand off to a raster they match exactly.

import CNeodiskCanvas
import Foundation
import NeodiskAppModel
import NeodiskKit
import SunburstCore
import WinSDK

@MainActor
final class SunburstPresenter {
    private unowned let host: CanvasHost
    private var model: VizCanvasModel { host.model }

    struct Inputs: Equatable, Sendable {
        var storeGeneration: Int
        var rootID: String
        var expandedAggregateIDs: Set<String>
        var freeSpaceBytes: Int64?
        var hiddenSpaceBytes: Int64?
        var style: SunburstColorStyle
        var size: CGSize
        var scale: Double
        var isDark: Bool
        var background: SIMD3<Float>
    }

    private struct Frame {
        let inputs: Inputs
        let segments: [SunburstSegment]
        let hitIndex: SunburstHitTestIndex
        let image: CanvasImage
        let renderedIDs: Set<String>
    }

    private struct Rendered: Sendable {
        let segments: [SunburstSegment]
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private var frame: Frame?
    private var inFlight: Inputs?
    private var hoveredSegment: SunburstSegment?
    private var hoverPoint: CGPoint?
    private var centerTexts: (title: CanvasText, detail: CanvasText, key: String)?
    private var lastFocusedRootID: String?
    private var wheelDrill = WheelDrillLatch()
    /// The drill animation in progress, if any.
    private var zoom: SunburstZoomTransitionState?

    init(host: CanvasHost) {
        self.host = host
    }

    var hasFrame: Bool { frame != nil }
    var isAnimating: Bool { zoom != nil }
    /// The raster is opaque and stretched over the canvas except while a drill animates.
    var coversCanvas: Bool { frame != nil && zoom == nil }

    func modelDidChange() {
        let focused = model.focusedRootID
        if focused != lastFocusedRootID {
            lastFocusedRootID = focused
            focusDidChange(to: focused)
        }
        requestRender()
        host.invalidate()
    }

    func deviceLost() {
        frame = nil
        inFlight = nil
        endZoom()
        requestRender()
    }

    // MARK: - Rendering

    private func currentInputs() -> Inputs? {
        guard let store = model.store, let focused = model.focusedRootID else { return nil }
        let size = host.viewSize
        guard size.width >= 1, size.height >= 1 else { return nil }
        let mode: SunburstColorStyle.Mode
        switch model.colorMode {
        case .branch: mode = .branch
        case .kind: mode = .kind
        case .age(let referenceDate): mode = .age(referenceDate: referenceDate)
        }
        return Inputs(
            storeGeneration: model.storeGeneration,
            rootID: store.node(id: focused) == nil ? store.rootID : focused,
            expandedAggregateIDs: model.expandedAggregateIDs,
            freeSpaceBytes: model.vizFreeSpaceBytes,
            hiddenSpaceBytes: model.vizHiddenSpaceBytes,
            style: SunburstColorStyle(mode: mode, catalog: model.catalog, highlight: model.highlight, palette: model.palette),
            size: size,
            scale: host.scale,
            isDark: model.isDarkTheme,
            background: model.vizBackgroundRGB
        )
    }

    func requestRender() {
        guard let inputs = currentInputs() else {
            if model.store == nil, frame != nil {
                frame = nil
                host.invalidate()
            }
            return
        }
        // The treemap on screen instead: render when this is shown again.
        guard host.isShowing(self), host.device != nil,
              inputs != frame?.inputs, inputs != inFlight, inFlight == nil,
              let store = model.store else { return }
        inFlight = inputs
        let mailbox = host.mailbox
        let stats = host.stats
        host.runInBackground { [weak self] in
            let rendered = Self.render(inputs: inputs, store: store, stats: stats)
            mailbox.post { [weak self] in
                self?.land(rendered, inputs: inputs)
            }
        }
    }

    private nonisolated static func render(inputs: Inputs, store: FileTreeStore, stats: CanvasStats) -> Rendered {
        let start = ContinuousClock.now
        let layout = (try? SunburstLayout.segments(
            in: store,
            rootID: inputs.rootID,
            depthLimit: SunburstPaint.depthLimit,
            freeSpaceBytes: inputs.freeSpaceBytes,
            hiddenSpaceBytes: inputs.hiddenSpaceBytes,
            expandedAggregateIDs: inputs.expandedAggregateIDs,
            freeSpaceLabel: AppStrings.text("Free Space"),
            hiddenSpaceLabel: AppStrings.text("Hidden Space"),
            cancellationCheck: {}
        )) ?? []
        let segments = SunburstLayout.styled(layout, style: inputs.style, in: store)
        let laidOut = ContinuousClock.now
        let geometry = SunburstGeometry(size: inputs.size)
        let arcs = segments.compactMap {
            geometry.arc(SunburstZoomGeometry.identityArc(for: $0),
                         fill: SunburstPaint.fill(for: $0, depth: Double($0.depth), palette: inputs.style.palette, isDark: inputs.isDark))
        }
        let width = Int((inputs.size.width * inputs.scale).rounded())
        let height = Int((inputs.size.height * inputs.scale).rounded())
        var pixels = [UInt8](repeating: 0, count: max(width * height * 4, 0))
        if width > 0, height > 0 {
            let separator = NDColor(SunburstPaint.separator(isDark: inputs.isDark))
            pixels.withUnsafeMutableBytes { buffer in
                arcs.withUnsafeBufferPointer { arcBuffer in
                    _ = ndc_rasterize_arcs(
                        UInt32(width), UInt32(height), Float(inputs.scale),
                        Float(geometry.center.x), Float(geometry.center.y),
                        arcBuffer.baseAddress, UInt32(arcs.count), separator, 1,
                        NDColor(inputs.background), buffer.baseAddress, UInt32(width * 4)
                    )
                }
            }
        }
        stats.record("sunburst.layout", ms: Clock.milliseconds(since: start) - Clock.milliseconds(since: laidOut))
        stats.record("sunburst.raster", ms: Clock.milliseconds(since: laidOut))
        stats.record("sunburst.render", ms: Clock.milliseconds(since: start))
        stats.record("sunburst.segments", ms: Double(segments.count))
        return Rendered(segments: segments, pixels: pixels, width: width, height: height)
    }

    private func land(_ rendered: Rendered, inputs: Inputs) {
        inFlight = nil
        let start = ContinuousClock.now
        if let device = host.device,
           let image = device.makeImage(
               pixels: rendered.pixels, width: rendered.width, height: rendered.height, stride: rendered.width * 4,
               isBGRA: true
           ) {
            host.stats.record("sunburst.upload", ms: Clock.milliseconds(since: start))
            frame = Frame(
                inputs: inputs,
                segments: rendered.segments,
                hitIndex: SunburstHitTestIndex(segments: rendered.segments),
                image: image,
                renderedIDs: Set(rendered.segments.compactMap(\.nodeID))
            )
            zoomLayoutDidLand()
            host.invalidate()
        }
        resolveHover()
        if currentInputs() != inputs {
            requestRender()
        }
    }

    // MARK: - Drawing

    func draw(into canvas: D2DCanvas, size: CGSize) {
        guard let frame else { return }
        if let zoom {
            let presentation = SunburstZoomPresentation(state: zoom, now: Date())
            if presentation.isFinished {
                endZoom()
            } else {
                drawZoom(zoom, presentation, into: canvas, size: size, inputs: frame.inputs)
                drawCenter(canvas, geometry: SunburstGeometry(size: size), isDark: frame.inputs.isDark)
                return
            }
        }
        // A resize in progress stretches the last frame until the new one lands.
        let isExact = frame.inputs.size == size
        canvas.draw(frame.image, in: CGRect(origin: .zero, size: size), sampling: isExact ? .opaque : .smooth)
        guard isExact else { return }

        let geometry = SunburstGeometry(size: size)
        let accent = NDColor(model.accentRGB)
        let selection = model.selection
        if let selected = selection.primaryID, let store = model.store {
            // Every selected arc, and the primary one's ancestors. Selected arcs draw after the ancestors, so a
            // selected ancestor keeps its selected stroke.
            var ancestorIDs = Set(store.path(to: selected).map(\.id))
            ancestorIDs.remove(selected)
            var selectedSegments: [SunburstSegment] = []
            for segment in frame.segments {
                guard let id = segment.nodeID else { continue }
                if selection.contains(id) {
                    selectedSegments.append(segment)
                } else if ancestorIDs.contains(id) {
                    geometry.overlay(canvas, segment, fill: nil, stroke: NDColor.white.withAlpha(0.35), width: 1.5)
                }
            }
            for segment in selectedSegments {
                geometry.overlay(canvas, segment, fill: NDColor.white.withAlpha(0.12), stroke: accent, width: 2.5)
            }
        }
        if let hovered = hoveredSegment {
            let stroke = frame.inputs.isDark ? NDColor.white.withAlpha(0.85) : NDColor.black.withAlpha(0.7)
            geometry.overlay(canvas, hovered, fill: NDColor.white.withAlpha(0.15), stroke: stroke, width: 2.5)
        }
        drawCenter(canvas, geometry: geometry, isDark: frame.inputs.isDark)
        if host.showsFocusRing {
            canvas.stroke(CGRect(origin: .zero, size: size), width: 2, accent.withAlpha(0.9))
        }
    }

    private func drawCenter(_ canvas: D2DCanvas, geometry: SunburstGeometry, isDark: Bool) {
        guard let store = model.store, let rootID = frame?.inputs.rootID, let root = store.node(id: rootID) else { return }
        let key = "\(root.id)|\(root.allocatedSize)|\(geometry.maxRadius)"
        if centerTexts?.key != key {
            let width = geometry.maxRadius * SunburstLayout.centerRadius * 1.6
            let title = root.name.isEmpty ? root.path : root.name
            guard let titleText = CanvasText(title, size: 14, bold: true, maxWidth: width, alignment: .center),
                  let detailText = CanvasText(NeodiskFormatters.size(root.allocatedSize), size: 12, maxWidth: width,
                                              alignment: .center) else { return }
            centerTexts = (titleText, detailText, key)
        }
        guard let centerTexts else { return }
        let total = centerTexts.title.height + centerTexts.detail.height
        let width = geometry.maxRadius * SunburstLayout.centerRadius * 1.6
        let color = isDark ? NDColor.white : NDColor.black.withAlpha(0.85)
        canvas.draw(centerTexts.title, at: CGPoint(x: geometry.center.x - width / 2, y: geometry.center.y - total / 2), color)
        canvas.draw(
            centerTexts.detail,
            at: CGPoint(x: geometry.center.x - width / 2, y: geometry.center.y - total / 2 + centerTexts.title.height),
            color.withAlpha(0.7)
        )
    }

    // MARK: - Drill animation

    /// Zoom-out waits for the parent layout to land. A new tree, unrendered target or disabled animations just
    /// swap.
    private func focusDidChange(to rootID: String?) {
        guard let frame, let rootID, let store = model.store,
              frame.inputs.storeGeneration == model.storeGeneration,
              frame.inputs.rootID != rootID,
              host.isShowing(self),
              systemAnimationsEnabled else {
            endZoom()
            return
        }
        let previousRootID = frame.inputs.rootID
        if let focus = frame.segments.first(where: { $0.nodeID == rootID && !$0.isAggregate }) {
            zoom = .zoomIn(segments: frame.segments, focus: focus)
        } else if store.isAncestor(rootID, of: previousRootID) {
            zoom = .zoomOut(previousSegments: frame.segments, previousRootID: previousRootID)
        } else {
            endZoom()
            return
        }
        hoveredSegment = nil
        host.invalidate()
    }

    /// Skips the zoom-out animation when the old root has no arc in the new layout.
    private func zoomLayoutDidLand() {
        guard var transition = zoom, transition.layoutReadyDate == nil, let frame,
              frame.inputs.rootID == model.focusedRootID else { return }
        switch transition.direction {
        case .zoomIn:
            guard let focus = transition.focus else {
                endZoom()
                return
            }
            transition.incomingSegments = frame.segments
            transition.handoffFadeDepthThreshold = SunburstZoomTransitionState.handoffFadeDepthThreshold(
                animatedSegments: transition.animatedSegments,
                focus: focus
            )
        case .zoomOut:
            guard let previousRootID = transition.previousRootID,
                  let focus = frame.segments.first(where: { $0.nodeID == previousRootID && !$0.isAggregate }) else {
                endZoom()
                return
            }
            transition.animatedSegments = frame.segments
            transition.focus = focus
            transition.handoffFadeDepthThreshold = SunburstZoomTransitionState.handoffFadeDepthThreshold(
                animatedSegments: frame.segments,
                focus: focus
            )
        }
        transition.layoutReadyDate = Date()
        zoom = transition
    }

    private func endZoom() {
        guard zoom != nil else { return }
        zoom = nil
        host.invalidate()
        resolveHover()
    }

    /// One frame of the drill: one scene per phase, as the other apps draw it.
    private func drawZoom(
        _ zoom: SunburstZoomTransitionState,
        _ presentation: SunburstZoomPresentation,
        into canvas: D2DCanvas,
        size: CGSize,
        inputs: Inputs
    ) {
        let painter = ArcPainter(geometry: SunburstGeometry(size: size), palette: inputs.style.palette, isDark: inputs.isDark)
        let metrics = SunburstRingMetrics(depthLimit: SunburstPaint.depthLimit)
        switch presentation.phase {
        case .zooming(let progress):
            guard let focus = zoom.focus else { return }
            painter.drawRemapped(canvas, zoom.animatedSegments, focus: focus, progress: progress, metrics: metrics)
        case .revealingIncoming(let alpha):
            painter.drawIdentity(canvas, zoom.incomingSegments, deepRingAlpha: alpha, deeperThan: zoom.handoffFadeDepthThreshold)
        case .holdingPrevious:
            painter.drawIdentity(canvas, zoom.previousSegments, deepRingAlpha: 1, deeperThan: .max)
        case .fadingOrphans(let alpha):
            if let focus = zoom.focus {
                painter.drawRemapped(canvas, zoom.animatedSegments, focus: focus, progress: 1, metrics: metrics)
            }
            // The orphaned rings sit in a band the remap leaves empty.
            painter.drawIdentity(
                canvas, zoom.previousSegments, deepRingAlpha: alpha,
                deeperThan: zoom.handoffFadeDepthThreshold, onlyDeepRings: true
            )
        }
    }

    // MARK: - Pointer

    private func segment(at point: CGPoint) -> SunburstSegment? {
        guard let frame else { return nil }
        return frame.hitIndex.segment(at: point, in: frame.inputs.size)
    }

    private func isInCenter(_ point: CGPoint) -> Bool {
        guard let frame else { return false }
        return SunburstCenterHitTester.contains(point: point, in: frame.inputs.size)
    }

    func pointerMoved(to point: CGPoint?) {
        hoverPoint = point
        resolveHover()
    }

    func resolveHover() {
        let segment = zoom == nil ? hoverPoint.flatMap { segment(at: $0) } : nil
        // Whole-value compare: a drill keeps a node's id but moves its arc.
        if segment != hoveredSegment {
            hoveredSegment = segment
            host.invalidate()
            model.vizStatusText(segment.map(statusText(for:)))
        }
        let hovered = segment.flatMap { $0.isFreeSpace || $0.isHiddenSpace ? nil : ($0.nodeID ?? $0.parentFolderID) }
        if model.hoveredNodeID != hovered {
            model.hoveredNodeID = hovered
        }
    }

    func pointerDown(button: Int, clickCount: Int, at point: CGPoint, ctrl: Bool, shift: Bool) {
        let click = MapClick(command: ctrl, shift: shift)
        // The chart is moving: nothing under the pointer is where it looks.
        guard zoom == nil else { return }
        if isInCenter(point) {
            if button == 1, click == .replace { model.focusOut() }
            return
        }
        guard let segment = segment(at: point), !segment.isFreeSpace, !segment.isHiddenSpace else {
            if button == 1, click == .replace { model.select(nil) }
            return
        }
        if segment.isAggregate {
            if button == 1, let folder = segment.parentFolderID {
                model.expandedAggregateIDs.insert(folder)
            }
            return
        }
        guard let nodeID = segment.nodeID else { return }
        switch button {
        case 1 where clickCount == 1 && click == .toggle:
            model.toggleSelection(nodeID)
        case 2:
            if !model.selection.contains(nodeID) { model.select(nodeID) }
        case 1 where clickCount >= 2:
            if !model.drillIn(to: nodeID) { host.beep() }
        case 1:
            model.select(nodeID)
        default:
            break
        }
    }

    func menuIncludesTrash(at point: CGPoint?) -> Bool {
        true
    }

    func menuAnchor() -> CGPoint? {
        guard let frame, let id = model.selection.primaryID,
              let segment = frame.segments.first(where: { $0.nodeID == id }) else { return nil }
        let geometry = SunburstGeometry(size: frame.inputs.size)
        let angle = (segment.startAngle + segment.endAngle) / 2 - .pi / 2
        let radius = geometry.maxRadius * (segment.innerRadius + segment.outerRadius) / 2
        return CGPoint(x: geometry.center.x + radius * cos(angle), y: geometry.center.y + radius * sin(angle))
    }

    /// Ctrl+wheel (and touchpad pinch) drills one level per notch: into the arc under the pointer, or out.
    func wheel(notches: Double, horizontal: Bool, at point: CGPoint, ctrl: Bool, shift: Bool) -> Bool {
        guard ctrl, !horizontal else { return false }
        switch wheelDrill.feed(notches: notches) {
        case .drillIn?:
            guard !isInCenter(point), let segment = segment(at: point),
                  !segment.isFreeSpace, !segment.isHiddenSpace,
                  let nodeID = segment.isAggregate ? segment.parentFolderID : segment.nodeID else { return true }
            if !model.drillIn(to: nodeID) { host.beep() }
        case .drillOut?:
            model.focusOut()
        case nil:
            break
        }
        return true
    }

    func didResize() {
        requestRender()
    }

    // MARK: - Keys

    func keyDown(vk: Int32, ctrl: Bool, shift: Bool, alt: Bool) -> Bool {
        guard let frame else { return false }
        if vk == 0x41, ctrl, !shift, !alt {  // Ctrl+A
            if !model.selectAllInMap() { host.beep() }
            return true
        }
        switch vk {
        case VK_RETURN:
            if !model.drillIntoSelection() { host.beep() }
        case VK_BACK:
            model.focusOut()
        default:
            guard let move = TreemapPresenter.treeMove(for: vk) else { return false }
            // Until the layout for the current root lands, every item counts.
            let ids = frame.renderedIDs
            let rendered: ((String) -> Bool)? = frame.inputs.rootID == model.focusedRootID ? { ids.contains($0) } : nil
            if !model.moveSelectionInMap(move, extending: shift, isRendered: rendered) {
                host.beep()
            }
        }
        return true
    }

    private func statusText(for segment: SunburstSegment) -> String {
        if segment.isAggregate {
            return AppStrings.format(
                "%lld smaller items · %@", Int64(segment.itemCount), NeodiskFormatters.size(segment.totalSize))
        }
        guard let id = segment.nodeID, let node = model.store?.node(id: id) else {
            return "\(segment.label) · \(NeodiskFormatters.size(segment.totalSize))"
        }
        return "\(node.name) · \(NeodiskFormatters.size(node.allocatedSize)) · \(node.path)"
    }

    // MARK: - Benchmark access

    var isRenderPending: Bool { inFlight != nil || currentInputs() != frame?.inputs }

    func benchmarkPoint(_ index: Int) -> CGPoint? {
        guard let frame, !frame.segments.isEmpty else { return nil }
        let segment = frame.segments[index % frame.segments.count]
        let geometry = SunburstGeometry(size: frame.inputs.size)
        let angle = (segment.startAngle + segment.endAngle) / 2 - .pi / 2
        let radius = geometry.maxRadius * (segment.innerRadius + segment.outerRadius) / 2
        return CGPoint(x: geometry.center.x + radius * cos(angle), y: geometry.center.y + radius * sin(angle))
    }

    /// The largest folder arc on the first ring, to drill into.
    var benchmarkDrillTarget: String? {
        frame?.segments.first { segment in
            segment.depth == 0 && !segment.isAggregate
                && segment.nodeID.flatMap { model.store?.node(id: $0)?.isDirectory } == true
        }?.nodeID
    }
}

// MARK: - Geometry

/// Arc geometry in DIPs: the chart is centered, its radius half the shorter side, angles clockwise from
/// 12 o'clock with the layout's seams.
struct SunburstGeometry: Sendable {
    let center: CGPoint
    let maxRadius: Double

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        maxRadius = min(size.width, size.height) / 2
    }

    /// The drawable arc with its seam insets, or nil when nothing is left of it.
    func arc(_ arc: SunburstZoomArc, fill: (rgb: SIMD3<Float>, opacity: Double)) -> NDArc? {
        let (seamStart, seamEnd) = SunburstArcGeometry.seamInsetAngles(
            startRadians: arc.startRadians,
            endRadians: arc.endRadians,
            innerRadius: arc.innerRadius,
            outerRadius: arc.outerRadius
        )
        let start = seamStart - .pi / 2
        let end = seamEnd - .pi / 2
        guard end > start else { return nil }
        return NDArc(
            start: Float(start), end: Float(end),
            inner: Float(maxRadius * arc.innerRadius), outer: Float(maxRadius * arc.outerRadius),
            fill: NDColor(fill.rgb, alpha: Float(fill.opacity))
        )
    }

    @MainActor
    func overlay(_ canvas: D2DCanvas, _ segment: SunburstSegment, fill: NDColor?, stroke: NDColor, width: Float) {
        guard var arc = arc(SunburstZoomGeometry.identityArc(for: segment), fill: (SIMD3(0, 0, 0), 0)) else { return }
        arc.fill = fill ?? .clear
        canvas.drawArcOverlay(center: center, arc, stroke: stroke, width: width)
    }
}

/// Paints arcs as Direct2D paths with the raster's styling, for the frames of a drill animation (the raster is
/// painted once per layout; these move).
@MainActor
private struct ArcPainter {
    let geometry: SunburstGeometry
    let palette: VizPalette
    let isDark: Bool

    private var separator: NDColor { NDColor(SunburstPaint.separator(isDark: isDark)) }

    func drawRemapped(
        _ canvas: D2DCanvas,
        _ segments: [SunburstSegment],
        focus: SunburstSegment,
        progress: Double,
        metrics: SunburstRingMetrics
    ) {
        var arcs: [NDArc] = []
        var opacities: [Float] = []
        arcs.reserveCapacity(segments.count)
        opacities.reserveCapacity(segments.count)
        for segment in segments {
            let opacity = SunburstZoomGeometry.opacity(for: segment, focus: focus, rawProgress: progress)
            guard opacity > 0.001 else { continue }
            let zoomArc = SunburstZoomGeometry.arc(for: segment, focus: focus, progress: progress, metrics: metrics)
            guard zoomArc.isDrawable else { continue }
            let depth = SunburstZoomGeometry.effectiveDepth(for: segment, focus: focus, progress: progress)
            guard let arc = geometry.arc(
                zoomArc, fill: SunburstPaint.fill(for: segment, depth: depth, palette: palette, isDark: isDark)
            ) else { continue }
            arcs.append(arc)
            opacities.append(Float(opacity))
        }
        canvas.drawArcs(center: geometry.center, arcs, opacities: opacities, separator: separator, width: 1)
    }

    func drawIdentity(
        _ canvas: D2DCanvas,
        _ segments: [SunburstSegment],
        deepRingAlpha: Double,
        deeperThan threshold: Int,
        onlyDeepRings: Bool = false
    ) {
        var arcs: [NDArc] = []
        var opacities: [Float] = []
        arcs.reserveCapacity(segments.count)
        opacities.reserveCapacity(segments.count)
        for segment in segments {
            let isDeep = segment.depth > threshold
            if onlyDeepRings, !isDeep { continue }
            let opacity = isDeep ? deepRingAlpha : 1
            guard opacity > 0.001 else { continue }
            let zoomArc = SunburstZoomGeometry.identityArc(for: segment)
            guard zoomArc.isDrawable, let arc = geometry.arc(
                zoomArc,
                fill: SunburstPaint.fill(for: segment, depth: Double(segment.depth), palette: palette, isDark: isDark)
            ) else { continue }
            arcs.append(arc)
            opacities.append(Float(opacity))
        }
        canvas.drawArcs(center: geometry.center, arcs, opacities: opacities, separator: separator, width: 1)
    }
}
