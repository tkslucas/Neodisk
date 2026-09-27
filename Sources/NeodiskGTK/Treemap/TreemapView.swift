//
//  TreemapView.swift
//  NeodiskGTK
//
//  The treemap on a NeodiskCanvas. Scene building (the shared
//  TreemapScene: squarified layout, cushion coefficients, small-item
//  aggregation, labels) and rasterization (TreemapKit) run off the main
//  actor; the finished RGBA raster becomes one GPU texture, and labels,
//  hover, and selection are drawn over it per frame from cached Pango
//  layouts — so moving the pointer never re-rasterizes the map.
//
//  Pinch and Ctrl+scroll zoom the viewport; while a crisp re-render is in
//  flight the previous texture is stretched through the shared resize
//  mapping, exactly as the macOS layer transform does.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit
import TreemapKit

@MainActor
final class TreemapView: CanvasDelegate {
    var widget: GPtr { canvas.widget }
    private let canvas = Canvas()
    private let model: AppModel

    /// Everything a frame depends on; a render starts only when it changes.
    private struct RenderInputs: Equatable {
        var storeGeneration: Int
        var rootID: String
        var size: CGSize
        var scale: Double
        var style: TreemapStyle
        var catalogBuildID: UUID
        var ageBuildID: UUID
        var colorMode: TreemapColorMode
        var highlight: TreemapHighlight?
        var paletteID: String
        var viewport: TreemapViewport
        var expandedAggregateIDs: Set<String>
        var freeSpaceBytes: Int64?
        var hiddenSpaceBytes: Int64?
        var isDark: Bool
    }

    private struct Frame {
        let inputs: RenderInputs
        let scene: TreemapScene
        let texture: GObjectRef
        let labels: [LabelLayout]
    }

    private struct LabelLayout {
        let label: TreemapScene.CellLabel
        let layout: GObjectRef
        let size: CGSize
    }

    private var frame: Frame?
    private var viewport = TreemapViewport.identity
    private var renderTask: Task<Void, Never>?
    private var inFlight: RenderInputs?
    private var selectionRect: (key: String, rect: CGRect)?
    /// The cell under the pointer, in scene coordinates.
    private var hoveredRect: CGRect?
    /// Last pointer position in view coordinates, nil once it leaves the
    /// map. Kept so the hover can re-resolve when a drill or zoom moves the
    /// cells under a pointer that hasn't moved.
    private var hoverPoint: CGPoint?
    private var zoomGestureStart: TreemapViewport?
    private var contextMenu: GPtr?
    private var tokens: [ObservationToken] = []

    init(model: AppModel) {
        self.model = model
        canvas.delegate = self
        gtk_widget_set_has_tooltip(ptr(canvas.widget), gbool(true))
        installControllers()

        tokens.append(track { [unowned self] in
            // Anything the scene depends on.
            _ = self.model.store.map { _ in self.model.storeGeneration }
            _ = self.model.focusedRootID
            _ = self.model.catalog.buildID
            _ = self.model.ageCatalog.buildID
            _ = self.model.colorMode
            _ = self.model.highlight
            _ = self.model.expandedAggregateIDs
            _ = self.model.preferences.treemapStyle
            _ = self.model.preferences.paletteID
            _ = self.model.preferences.showFreeSpace
            _ = self.model.volumeSpace
            self.requestRender()
        })
        tokens.append(track { [unowned self] in
            _ = self.model.selectedNodeID
            _ = self.model.hoveredNodeID
            self.canvas.queueDraw()
        })
        tokens.append(track { [unowned self] in
            // A new tree or focus starts unzoomed.
            _ = self.model.focusedRootID
            _ = self.model.target
            self.viewport = .identity
        })
        connectNotify(adw_style_manager_get_default().map { GPtr($0) }, "dark") { [unowned self] in
            self.requestRender()
        }
        connect(canvas.widget, "map") { [unowned self] in
            self.requestRender()
        }
    }

    // MARK: - Rendering

    private func currentInputs() -> RenderInputs? {
        guard let store = model.store, let rootID = model.focusedRootID else { return nil }
        let size = CGSize(width: canvas.width, height: canvas.height)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let showsVolumeSpace = model.focusID == nil && model.target?.kind == .volume
        return RenderInputs(
            storeGeneration: model.storeGeneration,
            rootID: store.node(id: rootID) == nil ? store.rootID : rootID,
            size: size,
            scale: canvas.scaleFactor,
            style: model.preferences.treemapStyle,
            catalogBuildID: model.catalog.buildID,
            ageBuildID: model.ageCatalog.buildID,
            colorMode: model.colorMode,
            highlight: model.highlight,
            paletteID: model.preferences.paletteID,
            viewport: viewport,
            expandedAggregateIDs: model.expandedAggregateIDs,
            freeSpaceBytes: showsVolumeSpace && model.preferences.showFreeSpace
                ? model.volumeSpace?.availableCapacity : nil,
            hiddenSpaceBytes: showsVolumeSpace ? model.hiddenSpaceBytes : nil,
            isDark: adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        )
    }

    /// Starts a render for the current inputs unless one for them is
    /// already on screen or in flight; a render that finishes stale starts
    /// the next one itself.
    func requestRender() {
        guard let inputs = currentInputs() else {
            if model.store == nil {
                frame = nil
                resolveHover()
                canvas.queueDraw()
            }
            return
        }
        // The sunburst on screen instead: render when this is shown again.
        guard gtk_widget_get_mapped(ptr(canvas.widget)) != 0 else { return }
        guard inputs != frame?.inputs, inputs != inFlight else { return }
        guard inFlight == nil else { return }
        inFlight = inputs

        guard let store = model.store else { return }
        let catalog = model.catalog
        let palette = model.preferences.palette
        let background = Self.backgroundRGB(isDark: inputs.isDark)
        renderTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> (TreemapScene, (pixels: [UInt8], width: Int, height: Int)?) in
                let scene = TreemapScene.build(
                    store: store,
                    rootID: inputs.rootID,
                    style: inputs.style,
                    size: inputs.size,
                    catalog: catalog,
                    colorMode: inputs.colorMode,
                    highlight: inputs.highlight,
                    expandedAggregateIDs: inputs.expandedAggregateIDs,
                    viewport: inputs.viewport,
                    freeSpaceBytes: inputs.freeSpaceBytes,
                    hiddenSpaceBytes: inputs.hiddenSpaceBytes,
                    palette: palette,
                    background: background
                )
                // Transparent clear: gaps show the live window background.
                let raster = inputs.style == .flat
                    ? FlatTreemapRenderer.rasterizeRGBA(cells: scene.cells, bounds: scene.renderBounds, scale: inputs.scale, background: nil)
                    : CushionTreemapRenderer.rasterizeRGBA(cells: scene.cells, bounds: scene.renderBounds, scale: inputs.scale, background: nil)
                return (scene, raster)
            }.value
            guard let self else { return }
            self.inFlight = nil
            if let raster = rendered.1,
               let texture = makeTexture(rgba: raster.pixels, width: raster.width, height: raster.height) {
                self.frame = Frame(
                    inputs: inputs,
                    scene: rendered.0,
                    texture: texture,
                    labels: self.makeLabels(for: rendered.0, isDark: inputs.isDark)
                )
                self.selectionRect = nil
                self.canvas.queueDraw()
            } else if rendered.0.cells.isEmpty {
                self.frame = nil
                self.canvas.queueDraw()
            }
            // The cells under a stationary pointer may have changed.
            self.resolveHover()
            // Inputs moved on while this render ran (resize, zoom, scan
            // progress): render again for the latest.
            if self.currentInputs() != inputs {
                self.requestRender()
            }
        }
    }

    /// The Adwaita window background the map sits on (flat fills composite
    /// against it).
    private static func backgroundRGB(isDark: Bool) -> SIMD3<Float> {
        isDark ? SIMD3(34, 34, 38) / 255 : SIMD3(250, 250, 251) / 255
    }

    /// A truncated label must keep this many characters to be worth
    /// drawing (the macOS rule — "A…" is clutter).
    private static let minUsefulTruncatedCharacters = 4

    private func makeLabels(for scene: TreemapScene, isDark: Bool) -> [LabelLayout] {
        var labels: [LabelLayout] = []
        labels.reserveCapacity(scene.labels.count)
        for label in scene.labels {
            let inset: Double = label.isHeader ? 0 : 4
            let width = max(label.rect.width - 2 * inset, 10)
            guard let layout = Text.layout(label.text, in: canvas.widget, maxWidth: width, bold: label.isHeader, scale: 0.9) else { continue }
            if pango_layout_is_ellipsized(ptr(layout.pointer)) != 0 {
                // Keep the label only if the first few characters fit.
                let prefix = String(label.text.prefix(Self.minUsefulTruncatedCharacters)) + "…"
                if let probe = Text.layout(prefix, in: canvas.widget, bold: label.isHeader, scale: 0.9),
                   Text.size(of: probe.pointer).width > width {
                    continue
                }
            }
            pango_layout_set_alignment(ptr(layout.pointer), label.isHeader ? PANGO_ALIGN_LEFT : PANGO_ALIGN_CENTER)
            labels.append(LabelLayout(label: label, layout: layout, size: Text.size(of: layout.pointer)))
        }
        return labels
    }

    // MARK: - CanvasDelegate

    func canvas(_ canvas: Canvas, didResizeTo width: Int, height: Int) {
        viewport = viewport.clamped(viewSize: CGSize(width: width, height: height))
        requestRender()
    }

    func canvas(_ canvas: Canvas, snapshot: GPtr, width: Double, height: Double) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let frame else { return }
        let mapping = displayMapping(for: frame)
        Snapshot.pushClip(snapshot, bounds)
        defer { Snapshot.pop(snapshot) }

        Snapshot.texture(snapshot, frame.texture.pointer, in: mapped(frame.scene.renderBounds, mapping))

        let isDark = frame.inputs.isDark
        let textColor = isDark ? RGBA.white : RGBA(red: 0, green: 0, blue: 0, alpha: 0.85)
        let isStretched = mapping != .identity
        if !isStretched {
            for label in frame.labels {
                let rect = label.label.rect
                let inset: Double = label.label.isHeader ? 0 : 4
                let origin = CGPoint(x: rect.minX + inset, y: rect.midY - label.size.height / 2)
                if isDark {
                    var shadow = GskShadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.9).gdk, dx: 0, dy: 0, radius: 2)
                    gtk_snapshot_push_shadow(ptr(snapshot), &shadow, 1)
                    Snapshot.layout(snapshot, label.layout.pointer, at: origin, textColor)
                    gtk_snapshot_pop(ptr(snapshot))
                } else {
                    Snapshot.layout(snapshot, label.layout.pointer, at: origin, textColor)
                }
            }
        }

        if let hoveredRect, model.hoveredNodeID != nil {
            Snapshot.stroke(snapshot, mapped(hoveredRect, mapping), width: 1.5, RGBA.white.withAlpha(0.8))
        }
        if let selected = model.selectedNodeID, let store = model.store,
           let rect = selectionRect(for: selected, in: frame, store: store) {
            Snapshot.stroke(snapshot, mapped(rect, mapping).insetBy(dx: -1, dy: -1), width: 3, RGBA.white)
            Snapshot.stroke(snapshot, mapped(rect, mapping), width: 2, Accent.color)
        }
    }

    private func selectionRect(for nodeID: String, in frame: Frame, store: FileTreeStore) -> CGRect? {
        if let cached = selectionRect, cached.key == nodeID { return cached.rect }
        // A folder's "smaller items" cell carries the folder's ID; the
        // folder's own rect comes from the layout.
        let rect = frame.scene.cells.last(where: { $0.nodeID == nodeID && $0.aggregate == nil })?.rect
            ?? frame.scene.rect(forNodeID: nodeID, in: store)
        if let rect { selectionRect = (nodeID, rect) }
        return rect
    }

    /// Maps the rendered frame into the live viewport while a zoom outruns
    /// re-rendering.
    private func displayMapping(for frame: Frame) -> TreemapDisplayMapping {
        TreemapResizePolicy.displayMapping(
            liveViewport: viewport,
            liveSize: CGSize(width: canvas.width, height: canvas.height),
            renderedViewport: frame.inputs.viewport,
            renderedSize: frame.inputs.size
        )
    }

    private func mapped(_ rect: CGRect, _ mapping: TreemapDisplayMapping) -> CGRect {
        guard mapping != .identity else { return rect }
        let origin = mapping.apply(to: rect.origin)
        let corner = mapping.apply(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }

    /// The scene cell under a point in live view coordinates.
    private func cell(at point: CGPoint) -> TreemapCell? {
        guard let frame else { return nil }
        let mapping = displayMapping(for: frame)
        let scenePoint = mapping == .identity ? point : CGPoint(
            x: (point.x - mapping.translationX) / mapping.scaleX,
            y: (point.y - mapping.translationY) / mapping.scaleY
        )
        return frame.scene.cell(at: scenePoint)
    }

    // MARK: - Input

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
            let button = gtk_gesture_single_get_current_button(ptr(click))
            gtk_widget_grab_focus(ptr(self.canvas.widget))
            self.handlePress(button: button, presses: presses, at: CGPoint(x: x, y: y))
        }
        gtk_widget_add_controller(ptr(widget), ptr(click))

        let scroll = raw(gtk_event_controller_scroll_new(
            GtkEventControllerScrollFlags(rawValue: GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES.rawValue)
        ))!
        connectScroll(scroll) { [unowned self] dx, dy in
            let state = gtk_event_controller_get_current_event_state(ptr(scroll))
            return self.handleScroll(dx: dx, dy: dy, control: state.rawValue & GDK_CONTROL_MASK.rawValue != 0)
        }
        gtk_widget_add_controller(ptr(widget), ptr(scroll))

        let zoom = raw(gtk_gesture_zoom_new())!
        connectPointer(zoom, "begin") { [unowned self] _ in
            self.zoomGestureStart = self.viewport
        }
        connectDouble(zoom, "scale-changed") { [unowned self] scale in
            guard let start = self.zoomGestureStart else { return }
            var x = 0.0
            var y = 0.0
            gtk_gesture_get_bounding_box_center(ptr(zoom), &x, &y)
            self.setViewport(start.zoomed(by: scale, anchor: CGPoint(x: x, y: y), viewSize: self.viewSize))
        }
        connectPointer(zoom, "end") { [unowned self] _ in
            self.zoomGestureStart = nil
        }
        gtk_widget_add_controller(ptr(widget), ptr(zoom))

        let keys = raw(gtk_event_controller_key_new())!
        connectKey(keys) { [unowned self] keyval, _ in
            self.handleKey(keyval)
        }
        gtk_widget_add_controller(ptr(widget), ptr(keys))

        connectTooltip(widget) { [unowned self] x, y, tooltip in
            guard let cell = self.cell(at: CGPoint(x: x, y: y)) else { return false }
            gtk_tooltip_set_text(ptr(tooltip), self.tooltipText(for: cell))
            return true
        }
    }

    private var viewSize: CGSize {
        CGSize(width: canvas.width, height: canvas.height)
    }

    private func setViewport(_ newViewport: TreemapViewport) {
        let clamped = newViewport.clamped(viewSize: viewSize)
        guard clamped != viewport else { return }
        viewport = clamped
        canvas.queueDraw()
        requestRender()
    }

    private func handlePress(button: UInt32, presses: Int, at point: CGPoint) {
        guard let cell = cell(at: point) else {
            if button == 1 { model.select(nil) }
            return
        }
        if cell.isFreeSpace || cell.isHiddenSpace {
            model.select(nil)
            return
        }
        switch button {
        case 3:
            model.select(cell.nodeID)
            showContextMenu(at: point)
        case 1 where presses >= 2:
            // As on the Mac: flat folders are first-class targets and drill
            // in; cushion cells (and files) keep the reveal-in-file-manager
            // contract — the mouse never drills a cushion map.
            if model.preferences.treemapStyle == .flat, cell.isDirectory {
                model.drillIn(to: cell.nodeID)
            } else if let node = model.store?.node(id: cell.nodeID) {
                model.select(cell.nodeID)
                FileActions.showInFileManager(node.path, from: raw(gtk_widget_get_root(ptr(canvas.widget))))
            }
        case 1:
            // Clicking a "smaller items" cell opens its folder's tail up.
            if cell.aggregate != nil {
                model.expandedAggregateIDs.insert(cell.nodeID)
            }
            model.select(cell.nodeID)
        default:
            break
        }
    }

    /// Hit-tests the last pointer position against the frame on screen.
    private func resolveHover() {
        let cell = hoverPoint.flatMap { cell(at: $0) }
        let hovered = cell.flatMap { $0.isFreeSpace || $0.isHiddenSpace ? nil : $0.nodeID }
        if hoveredRect != cell?.rect {
            hoveredRect = cell?.rect
            canvas.queueDraw()
        }
        if model.hoveredNodeID != hovered {
            model.hoveredNodeID = hovered
            // A showing tooltip would keep describing the old cell.
            gtk_widget_trigger_tooltip_query(ptr(canvas.widget))
        }
    }

    /// Ctrl+scroll zooms at the pointer; plain scroll pans a zoomed map.
    private func handleScroll(dx: Double, dy: Double, control: Bool) -> Bool {
        guard frame != nil else { return false }
        if control {
            var x = 0.0
            var y = 0.0
            if let surface = gtk_native_get_surface(gtk_widget_get_native(ptr(canvas.widget))),
               let seat = gdk_display_get_default_seat(gdk_display_get_default()),
               let pointer = gdk_seat_get_pointer(seat) {
                var mask = GdkModifierType(rawValue: 0)
                gdk_surface_get_device_position(surface, pointer, &x, &y, &mask)
                var point = graphene_point_t(x: Float(x), y: Float(y))
                var local = graphene_point_t()
                if let native = gtk_widget_get_native(ptr(canvas.widget)),
                   gtk_widget_compute_point(ptr(raw(native)), ptr(canvas.widget), &point, &local) != 0 {
                    x = Double(local.x)
                    y = Double(local.y)
                }
            }
            let factor = exp(-dy * 0.15)
            setViewport(viewport.zoomed(by: factor, anchor: CGPoint(x: x, y: y), viewSize: viewSize))
            return true
        }
        guard viewport.scale > 1.0001 else { return false }
        setViewport(viewport.panned(by: CGSize(width: -dx * 30, height: -dy * 30), viewSize: viewSize))
        return true
    }

    private func handleKey(_ keyval: UInt32) -> Bool {
        guard let frame else { return false }
        let direction: TreemapKeyboardNav.Direction?
        switch Int32(keyval) {
        case GDK_KEY_Left: direction = .left
        case GDK_KEY_Right: direction = .right
        case GDK_KEY_Up: direction = .up
        case GDK_KEY_Down: direction = .down
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            if !model.drillIntoSelection() {
                gtk_widget_error_bell(ptr(canvas.widget))
            }
            return true
        case GDK_KEY_BackSpace:
            model.focusOut()
            return true
        case GDK_KEY_Escape:
            if viewport != .identity {
                setViewport(.identity)
            } else {
                model.select(nil)
            }
            return true
        default:
            direction = nil
        }
        guard let direction else { return false }
        let candidates = TreemapKeyboardNav.candidates(in: frame.scene.cells)
        let origin = model.selectedNodeID
            .flatMap { id in candidates.first { $0.nodeID == id } }?.center
        let next: String?
        if let origin {
            next = TreemapKeyboardNav.target(from: origin, direction: direction, excluding: model.selectedNodeID, in: candidates)
        } else {
            next = TreemapKeyboardNav.largest(in: candidates)
        }
        if let next {
            model.select(next)
        } else {
            gtk_widget_error_bell(ptr(canvas.widget))
        }
        return true
    }

    private func tooltipText(for cell: TreemapCell) -> String {
        if cell.isFreeSpace {
            return L("Free space · %@", NeodiskFormatters.size(model.volumeSpace?.availableCapacity ?? 0))
        }
        if cell.isHiddenSpace {
            return L("Hidden space · %@", NeodiskFormatters.size(model.hiddenSpaceBytes ?? 0))
        }
        if let aggregate = cell.aggregate {
            return L("%lld smaller items · %@", Int64(aggregate.itemCount), NeodiskFormatters.size(aggregate.totalSize))
        }
        guard let node = model.store?.node(id: cell.nodeID) else { return cell.nodeID }
        return "\(node.name)\n\(NeodiskFormatters.size(node.allocatedSize)) · \(DisplayFormatters.displayPath(node.path))"
    }

    private func showContextMenu(at point: CGPoint) {
        Widgets.popupMenu(&contextMenu, sections: [
            [(L("Open"), "win.open-item"), (L("Show in Files"), "win.show-in-files"), (L("Copy Path"), "win.copy-path")],
            [(L("Zoom In"), "win.focus-in"), (L("Zoom Out"), "win.focus-out")],
        ], on: canvas.widget, at: point)
    }
}
