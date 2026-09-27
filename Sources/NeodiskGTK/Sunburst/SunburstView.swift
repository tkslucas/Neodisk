//
//  SunburstView.swift
//  NeodiskGTK
//
//  The sunburst on a NeodiskCanvas. Layout (SunburstCore) and the fill pass
//  (NeodiskAppModel's `styled`) are the same code the Mac runs; the arcs are
//  painted once per layout into a cairo raster that becomes a GPU texture,
//  and hover/selection highlights are GskPath fills and strokes on top — so
//  pointer movement never repaints thousands of arcs. The center shows the
//  folder the chart is drilled into; clicking it drills back out.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit
import SunburstCore

@MainActor
final class SunburstView: CanvasDelegate {
    var widget: GPtr { canvas.widget }
    private let canvas = Canvas()
    private let model: AppModel

    /// Rings drawn below the center, as on the Mac.
    nonisolated static let depthLimit = 8

    private struct Inputs: Equatable {
        var storeGeneration: Int
        var rootID: String
        var expandedAggregateIDs: Set<String>
        var freeSpaceBytes: Int64?
        var hiddenSpaceBytes: Int64?
        var style: SunburstColorStyle
        var size: CGSize
        var scale: Double
        var isDark: Bool
    }

    private struct Frame {
        let inputs: Inputs
        let segments: [SunburstSegment]
        let hitIndex: SunburstHitTestIndex
        let texture: GObjectRef
        let renderedIDs: Set<String>
    }

    private var frame: Frame?
    private var inFlight: Inputs?
    private var renderTask: Task<Void, Never>?
    private var hoveredSegment: SunburstSegment?
    /// Last pointer position, nil once it leaves; re-resolved when a new
    /// layout lands under a pointer that hasn't moved.
    private var hoverPoint: CGPoint?
    private var centerLayouts: (title: GObjectRef, detail: GObjectRef, key: String)?
    private var contextMenu: GPtr?
    private var tokens: [ObservationToken] = []

    init(model: AppModel) {
        self.model = model
        canvas.delegate = self
        gtk_widget_set_has_tooltip(ptr(canvas.widget), gbool(true))
        installControllers()

        tokens.append(track { [unowned self] in
            _ = self.model.store.map { _ in self.model.storeGeneration }
            _ = self.model.focusedRootID
            _ = self.model.catalog.buildID
            _ = self.model.ageCatalog.buildID
            _ = self.model.colorMode
            _ = self.model.highlight
            _ = self.model.expandedAggregateIDs
            _ = self.model.preferences.paletteID
            _ = self.model.preferences.showFreeSpace
            _ = self.model.volumeSpace
            self.requestRender()
        })
        tokens.append(track { [unowned self] in
            _ = self.model.selectedNodeID
            self.canvas.queueDraw()
        })
        connectNotify(adw_style_manager_get_default().map { GPtr($0) }, "dark") { [unowned self] in
            self.requestRender()
        }
    }

    // MARK: - Rendering

    private func currentInputs() -> Inputs? {
        guard let store = model.store, let focused = model.focusedRootID else { return nil }
        let size = CGSize(width: canvas.width, height: canvas.height)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let showsVolumeSpace = model.focusID == nil && model.target?.kind == .volume
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
            freeSpaceBytes: showsVolumeSpace && model.preferences.showFreeSpace ? model.volumeSpace?.availableCapacity : nil,
            hiddenSpaceBytes: showsVolumeSpace ? model.hiddenSpaceBytes : nil,
            style: SunburstColorStyle(mode: mode, catalog: model.catalog, highlight: model.highlight, palette: model.palette),
            size: size,
            scale: canvas.scaleFactor,
            isDark: adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        )
    }

    private func requestRender() {
        guard let inputs = currentInputs() else {
            if model.store == nil {
                frame = nil
                canvas.queueDraw()
            }
            return
        }
        guard inputs != frame?.inputs, inputs != inFlight, inFlight == nil,
              let store = model.store else { return }
        inFlight = inputs
        renderTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> ([SunburstSegment], SunburstRaster?) in
                let layout = (try? SunburstLayout.segments(
                    in: store,
                    rootID: inputs.rootID,
                    depthLimit: SunburstView.depthLimit,
                    freeSpaceBytes: inputs.freeSpaceBytes,
                    hiddenSpaceBytes: inputs.hiddenSpaceBytes,
                    expandedAggregateIDs: inputs.expandedAggregateIDs,
                    freeSpaceLabel: L("Free Space"),
                    hiddenSpaceLabel: L("Hidden Space"),
                    cancellationCheck: {}
                )) ?? []
                let styled = SunburstLayout.styled(layout, style: inputs.style, in: store)
                let raster = SunburstRaster.render(
                    styled,
                    size: inputs.size,
                    scale: inputs.scale,
                    palette: inputs.style.palette,
                    isDark: inputs.isDark
                )
                return (styled, raster)
            }.value
            guard let self else { return }
            self.inFlight = nil
            if let raster = rendered.1,
               let texture = makeTexture(bgra: raster.pixels, width: raster.width, height: raster.height, stride: raster.stride) {
                self.frame = Frame(
                    inputs: inputs,
                    segments: rendered.0,
                    hitIndex: SunburstHitTestIndex(segments: rendered.0),
                    texture: texture,
                    renderedIDs: Set(rendered.0.compactMap(\.nodeID))
                )
                self.canvas.queueDraw()
            }
            self.resolveHover()
            if self.currentInputs() != inputs {
                self.requestRender()
            }
        }
    }

    // MARK: - CanvasDelegate

    func canvas(_ canvas: Canvas, didResizeTo width: Int, height: Int) {
        requestRender()
    }

    func canvas(_ canvas: Canvas, snapshot: GPtr, width: Double, height: Double) {
        guard let frame else { return }
        let size = frame.inputs.size
        // A resize in progress stretches the last frame until the new one lands.
        Snapshot.texture(snapshot, frame.texture.pointer, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard size.width == width, size.height == height else { return }

        let geometry = SunburstGeometry(size: size)
        if let selected = model.selectedNodeID, let store = model.store {
            // The selected arc and its ancestors, like the Mac's overlay.
            var ancestorIDs = Set(store.path(to: selected).map(\.id))
            ancestorIDs.remove(selected)
            for segment in frame.segments {
                guard let id = segment.nodeID else { continue }
                if id == selected {
                    geometry.overlay(snapshot, segment, fill: RGBA.white.withAlpha(0.12), stroke: Accent.color, width: 2.5)
                } else if ancestorIDs.contains(id) {
                    geometry.overlay(snapshot, segment, fill: nil, stroke: RGBA.white.withAlpha(0.35), width: 1.5)
                }
            }
        }
        if let hovered = hoveredSegment {
            let stroke = frame.inputs.isDark ? RGBA.white.withAlpha(0.85) : RGBA.black.withAlpha(0.7)
            geometry.overlay(snapshot, hovered, fill: RGBA.white.withAlpha(0.15), stroke: stroke, width: 2.5)
        }
        drawCenter(snapshot, geometry: geometry, isDark: frame.inputs.isDark)
    }

    private func drawCenter(_ snapshot: GPtr, geometry: SunburstGeometry, isDark: Bool) {
        guard let store = model.store, let root = store.node(id: frame?.inputs.rootID) else { return }
        let key = "\(root.id)|\(root.allocatedSize)"
        if centerLayouts?.key != key {
            let title = root.id == store.rootID
                ? (model.target.map { $0.id == "/" ? L("Computer") : $0.displayName } ?? root.name)
                : root.name
            let width = geometry.maxRadius * SunburstLayout.centerRadius * 1.6
            guard let titleLayout = Text.layout(title, in: canvas.widget, maxWidth: width, bold: true),
                  let detailLayout = Text.layout(NeodiskFormatters.size(root.allocatedSize), in: canvas.widget, maxWidth: width, scale: 0.9) else { return }
            pango_layout_set_alignment(ptr(titleLayout.pointer), PANGO_ALIGN_CENTER)
            pango_layout_set_alignment(ptr(detailLayout.pointer), PANGO_ALIGN_CENTER)
            centerLayouts = (titleLayout, detailLayout, key)
        }
        guard let centerLayouts else { return }
        let titleSize = Text.size(of: centerLayouts.title.pointer)
        let detailSize = Text.size(of: centerLayouts.detail.pointer)
        let total = titleSize.height + detailSize.height
        let color = isDark ? RGBA.white : RGBA.black.withAlpha(0.85)
        Snapshot.layout(snapshot, centerLayouts.title.pointer,
                        at: CGPoint(x: geometry.center.x - titleSize.width / 2, y: geometry.center.y - total / 2), color)
        Snapshot.layout(snapshot, centerLayouts.detail.pointer,
                        at: CGPoint(x: geometry.center.x - detailSize.width / 2, y: geometry.center.y - total / 2 + titleSize.height),
                        color.withAlpha(0.7))
    }

    // MARK: - Input

    private func segment(at point: CGPoint) -> SunburstSegment? {
        guard let frame else { return nil }
        return frame.hitIndex.segment(at: point, in: frame.inputs.size)
    }

    private func isInCenter(_ point: CGPoint) -> Bool {
        guard let frame else { return false }
        return SunburstCenterHitTester.contains(point: point, in: frame.inputs.size)
    }

    /// Hit-tests the last pointer position against the layout on screen.
    private func resolveHover() {
        let segment = hoverPoint.flatMap { segment(at: $0) }
        // Whole-value compare: a drill keeps a node's id but moves its arc.
        if segment != hoveredSegment {
            hoveredSegment = segment
            canvas.queueDraw()
        }
        let hovered = segment.flatMap { $0.isFreeSpace || $0.isHiddenSpace ? nil : ($0.nodeID ?? $0.parentFolderID) }
        if model.hoveredNodeID != hovered {
            model.hoveredNodeID = hovered
        }
    }

    private func installControllers() {
        let widget = canvas.widget

        let motion = raw(gtk_event_controller_motion_new())!
        connectPoint(motion, "motion") { [unowned self] x, y in
            self.hoverPoint = CGPoint(x: x, y: y)
            self.resolveHover()
        }
        connect(motion, "leave") { [unowned self] in
            self.hoverPoint = nil
            self.resolveHover()
        }
        gtk_widget_add_controller(ptr(widget), ptr(motion))

        let click = raw(gtk_gesture_click_new())!
        gtk_gesture_single_set_button(ptr(click), 0)
        connectPress(click, "pressed") { [unowned self] presses, x, y in
            gtk_widget_grab_focus(ptr(self.canvas.widget))
            let button = gtk_gesture_single_get_current_button(ptr(click))
            self.handlePress(button: button, presses: presses, at: CGPoint(x: x, y: y))
        }
        gtk_widget_add_controller(ptr(widget), ptr(click))

        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, _ in
            self.handleKey(keyval)
        }
        gtk_widget_add_controller(ptr(widget), ptr(keys))

        connectTooltip(widget) { [unowned self] x, y, tooltip in
            guard let segment = self.segment(at: CGPoint(x: Double(x), y: Double(y))) else { return false }
            gtk_tooltip_set_text(ptr(tooltip), self.tooltipText(for: segment))
            return true
        }
    }

    private func handlePress(button: UInt32, presses: Int, at point: CGPoint) {
        if isInCenter(point) {
            if button == 1 { model.focusOut() }
            return
        }
        guard let segment = segment(at: point), !segment.isFreeSpace, !segment.isHiddenSpace else {
            if button == 1 { model.select(nil) }
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
        case 3:
            model.select(nodeID)
            showContextMenu(at: point)
        case 1 where presses >= 2:
            model.drillIn(to: nodeID)
        case 1:
            model.select(nodeID)
        default:
            break
        }
    }

    private func handleKey(_ keyval: UInt32) -> Bool {
        guard let frame, let store = model.store else { return false }
        let direction: SunburstKeyboardNav.Direction
        switch Int32(keyval) {
        case GDK_KEY_Left: direction = .previousSibling
        case GDK_KEY_Right: direction = .nextSibling
        case GDK_KEY_Up: direction = .parent
        case GDK_KEY_Down: direction = .largestChild
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            if !model.drillIntoSelection() {
                gtk_widget_error_bell(ptr(canvas.widget))
            }
            return true
        case GDK_KEY_BackSpace:
            model.focusOut()
            return true
        case GDK_KEY_Escape:
            model.select(nil)
            return true
        default:
            return false
        }
        let rendered = frame.renderedIDs
        if let next = SunburstKeyboardNav.target(
            from: model.selectedNodeID,
            direction: direction,
            rootID: frame.inputs.rootID,
            store: store,
            isRendered: { rendered.contains($0) }
        ) {
            model.select(next)
        } else {
            gtk_widget_error_bell(ptr(canvas.widget))
        }
        return true
    }

    private func tooltipText(for segment: SunburstSegment) -> String {
        if segment.isAggregate {
            return L("%lld smaller items · %@", Int64(segment.itemCount), NeodiskFormatters.size(segment.totalSize))
        }
        guard let id = segment.nodeID, let node = model.store?.node(id: id) else {
            return "\(segment.label)\n\(NeodiskFormatters.size(segment.totalSize))"
        }
        return "\(node.name)\n\(NeodiskFormatters.size(node.allocatedSize)) · \(DisplayFormatters.displayPath(node.path))"
    }

    private func showContextMenu(at point: CGPoint) {
        if contextMenu == nil {
            let menu = Widgets.menu([
                [(L("Open"), "win.open-item"), (L("Show in Files"), "win.show-in-files"), (L("Copy Path"), "win.copy-path")],
                [(L("Zoom In"), "win.focus-in"), (L("Zoom Out"), "win.focus-out")],
            ])
            let popover = raw(gtk_popover_menu_new_from_model(ptr(menu.pointer)))!
            gtk_widget_set_parent(ptr(popover), ptr(canvas.widget))
            gtk_popover_set_has_arrow(ptr(popover), gbool(false))
            contextMenu = popover
        }
        var rect = GdkRectangle(x: Int32(point.x), y: Int32(point.y), width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(contextMenu), &rect)
        gtk_popover_popup(ptr(contextMenu))
    }
}

// MARK: - Geometry

/// Arc geometry in view points: the chart is centered, its radius half the
/// shorter side, angles clockwise from 12 o'clock with the layout's seams.
struct SunburstGeometry {
    let center: CGPoint
    let maxRadius: Double

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        maxRadius = min(size.width, size.height) / 2
    }

    func seamAngles(_ segment: SunburstSegment) -> (start: Double, end: Double) {
        let (start, end) = SunburstArcGeometry.seamInsetAngles(
            startRadians: segment.startAngle,
            endRadians: segment.endAngle,
            innerRadius: segment.innerRadius,
            outerRadius: segment.outerRadius
        )
        return (start - .pi / 2, end - .pi / 2)
    }

    func point(radius: Double, angle: Double) -> (Float, Float) {
        (Float(center.x + radius * cos(angle)), Float(center.y + radius * sin(angle)))
    }

    /// The arc as a GskPath; spans over half a turn are split so every SVG
    /// arc command stays well-defined.
    @MainActor
    func path(for segment: SunburstSegment) -> OpaquePointer? {
        let (start, end) = seamAngles(segment)
        guard end > start else { return nil }
        let outer = maxRadius * segment.outerRadius
        let inner = maxRadius * segment.innerRadius
        let builder = gsk_path_builder_new()
        let steps = end - start > .pi ? 2 : 1
        let step = (end - start) / Double(steps)
        var (x, y) = point(radius: outer, angle: start)
        gsk_path_builder_move_to(builder, x, y)
        for index in 1...steps {
            (x, y) = point(radius: outer, angle: start + step * Double(index))
            gsk_path_builder_svg_arc_to(builder, Float(outer), Float(outer), 0, gbool(false), gbool(true), x, y)
        }
        (x, y) = point(radius: inner, angle: end)
        gsk_path_builder_line_to(builder, x, y)
        if inner > 0.5 {
            for index in stride(from: steps - 1, through: 0, by: -1) {
                (x, y) = point(radius: inner, angle: start + step * Double(index))
                gsk_path_builder_svg_arc_to(builder, Float(inner), Float(inner), 0, gbool(false), gbool(false), x, y)
            }
        }
        gsk_path_builder_close(builder)
        return gsk_path_builder_free_to_path(builder)
    }

    @MainActor
    func overlay(_ snapshot: GPtr, _ segment: SunburstSegment, fill: RGBA?, stroke: RGBA, width: Float) {
        guard let path = path(for: segment) else { return }
        defer { gsk_path_unref(path) }
        if let fill {
            var color = fill.gdk
            gtk_snapshot_append_fill(ptr(snapshot), path, GSK_FILL_RULE_WINDING, &color)
        }
        let strokeStyle = gsk_stroke_new(width)
        defer { gsk_stroke_free(strokeStyle) }
        var color = stroke.gdk
        gtk_snapshot_append_stroke(ptr(snapshot), path, strokeStyle, &color)
    }
}

/// The painted arcs as premultiplied BGRA pixels (cairo's ARGB32).
struct SunburstRaster: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let stride: Int

    /// Paints `segments` with the Mac's styling: depth-faded fills, muted
    /// aggregates and synthetic space arcs, hairline separators.
    nonisolated static func render(
        _ segments: [SunburstSegment],
        size: CGSize,
        scale: Double,
        palette: VizPalette,
        isDark: Bool
    ) -> SunburstRaster? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let stride = Int(cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, Int32(width)))
        var pixels = [UInt8](repeating: 0, count: stride * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let surface = cairo_image_surface_create_for_data(base, CAIRO_FORMAT_ARGB32, Int32(width), Int32(height), Int32(stride)) else { return }
            defer { cairo_surface_destroy(surface) }
            guard let cairo = cairo_create(surface) else { return }
            defer { cairo_destroy(cairo) }
            cairo_scale(cairo, scale, scale)
            let center = (x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2
            let separator: (Double, Double, Double, Double) = isDark ? (1, 1, 1, 0.08) : (0, 0, 0, 0.1)
            for segment in segments {
                let (seamStart, seamEnd) = SunburstArcGeometry.seamInsetAngles(
                    startRadians: segment.startAngle,
                    endRadians: segment.endAngle,
                    innerRadius: segment.innerRadius,
                    outerRadius: segment.outerRadius
                )
                let start = seamStart - .pi / 2
                let end = seamEnd - .pi / 2
                guard end > start else { continue }
                cairo_new_path(cairo)
                cairo_arc(cairo, center.x, center.y, maxRadius * segment.outerRadius, start, end)
                cairo_arc_negative(cairo, center.x, center.y, maxRadius * segment.innerRadius, end, start)
                cairo_close_path(cairo)
                let (rgb, opacity) = fill(for: segment, palette: palette, isDark: isDark)
                cairo_set_source_rgba(cairo, Double(rgb.x), Double(rgb.y), Double(rgb.z), opacity)
                cairo_fill_preserve(cairo)
                cairo_set_source_rgba(cairo, separator.0, separator.1, separator.2, separator.3)
                cairo_set_line_width(cairo, 1)
                cairo_stroke(cairo)
            }
        }
        return SunburstRaster(pixels: pixels, width: width, height: height, stride: stride)
    }

    private nonisolated static func fill(for segment: SunburstSegment, palette: VizPalette, isDark: Bool) -> (SIMD3<Float>, Double) {
        switch segment.colorToken.role {
        case .freeSpace:
            return (SIMD3(0.56, 0.56, 0.58), 0.34)
        case .hiddenSpace:
            return (SIMD3(0.33, 0.33, 0.35), 0.4)
        case .aggregate:
            return (isDark ? SIMD3(0.6, 0.6, 0.62) : SIMD3(0.45, 0.45, 0.47), 0.22)
        default:
            let rgb = segment.fillRGB ?? SunburstColorResolver.rgb(for: segment.colorToken, palette: palette.sunburst)
            let opacity = max(0.24, 0.78 - Double(segment.depth) * 0.09 - (segment.isAggregate ? 0.16 : 0))
            return (rgb, opacity)
        }
    }
}

/// A GdkTexture over premultiplied BGRA pixels (cairo ARGB32 on
/// little-endian machines).
@MainActor
func makeTexture(bgra pixels: [UInt8], width: Int, height: Int, stride: Int) -> GObjectRef? {
    guard width > 0, height > 0, pixels.count >= stride * height else { return nil }
    let bytes = pixels.withUnsafeBytes { buffer in
        g_bytes_new(buffer.baseAddress, gsize(buffer.count))
    }
    defer { g_bytes_unref(bytes) }
    guard let texture = gdk_memory_texture_new(
        Int32(width), Int32(height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride)
    ) else { return nil }
    return GObjectRef(adopting: raw(texture)!)
}
