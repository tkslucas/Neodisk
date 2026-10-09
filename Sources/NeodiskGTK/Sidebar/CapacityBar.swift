//
//  CapacityBar.swift
//  NeodiskGTK
//
//  The capacity bar under a sidebar volume, as on the Mac: once the volume
//  has been scanned, one segment per file kind category in the Kinds tab's
//  colors, a neutral tail for used space the scan couldn't see, and the
//  empty track for free space. Hovering a stretch shows its name and size
//  in a bubble pointing at it. Before any scan it's a plain used/total bar.
//  Under a scanned folder (no space of its own) the categories alone fill
//  it, and it hides until there is a scan.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

@MainActor
final class CapacityBar: CanvasDelegate {
    var widget: GPtr { canvas.widget }
    private let canvas = Canvas()
    private let space: VolumeSpaceInfo?
    private let bubble: GPtr
    private let bubbleTitle: GPtr
    private let bubbleSize: GPtr
    private var hoveredID: String?
    private var hideTask: Task<Void, Never>?

    /// Category segments from the last scan; empty until there is one.
    var segments: [VolumeCapacitySegment] = [] {
        didSet {
            guard segments != oldValue else { return }
            if space == nil {
                Widgets.setVisible(canvas.widget, !segments.isEmpty)
            }
            canvas.queueDraw()
            if let hoveredID { hover(at: nil, id: hoveredID) }
        }
    }

    private static let height = 6
    private static let freeTrackID = "free-track"

    init(space: VolumeSpaceInfo?) {
        self.space = space
        gtk_widget_set_vexpand(ptr(canvas.widget), gbool(false))
        gtk_widget_set_focusable(ptr(canvas.widget), gbool(false))
        gtk_widget_set_size_request(ptr(canvas.widget), -1, Int32(Self.height))

        bubbleTitle = Widgets.label("", xalign: 0.5, classes: ["heading", "neodisk-caption"])
        bubbleSize = Widgets.label("", xalign: 0.5, classes: ["dim-label", "neodisk-caption", "neodisk-numeric"])
        let content = Widgets.box(GTK_ORIENTATION_VERTICAL, spacing: 1, [bubbleTitle, bubbleSize])
        bubble = raw(gtk_popover_new())!
        gtk_popover_set_child(ptr(bubble), ptr(content))
        gtk_popover_set_autohide(ptr(bubble), gbool(false))
        gtk_popover_set_position(ptr(bubble), GTK_POS_TOP)
        gtk_widget_set_can_target(ptr(bubble), gbool(false))
        gtk_widget_set_can_focus(ptr(bubble), gbool(false))
        Widgets.addClasses(bubble, ["neodisk-bubble"])
        gtk_widget_set_parent(ptr(bubble), ptr(canvas.widget))
        canvas.delegate = self
        attach(self, to: canvas.widget, key: "neodisk-capacity-bar")
        if space == nil {
            Widgets.setVisible(canvas.widget, false)
        }

        let motion = raw(gtk_event_controller_motion_new())!
        connectPoint(motion, "enter") { [unowned self] x, _ in self.hover(at: x) }
        connectPoint(motion, "motion") { [unowned self] x, _ in self.hover(at: x) }
        connect(motion, "leave") { [unowned self] in self.scheduleHide() }
        gtk_widget_add_controller(ptr(canvas.widget), ptr(motion))
        // The bubble is parented to the canvas and must go before it does.
        connect(canvas.widget, "destroy") { [unowned self] in
            self.hideTask?.cancel()
            gtk_widget_unparent(ptr(self.bubble))
        }
    }

    // MARK: - Drawing

    func canvas(_ canvas: Canvas, didResizeTo width: Int, height: Int) {
        // A popover's parent positions it on every allocation.
        if gtk_widget_get_visible(ptr(bubble)) != 0 {
            gtk_popover_present(ptr(bubble))
        }
    }

    func canvas(_ canvas: Canvas, snapshot: GPtr, width: Double, height: Double) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var rect = grapheneRect(bounds)
        var capsule = GskRoundedRect()
        gsk_rounded_rect_init_from_rect(&capsule, &rect, Float(height / 2))
        gtk_snapshot_push_rounded_clip(ptr(snapshot), &capsule)
        defer { gtk_snapshot_pop(ptr(snapshot)) }

        let isDark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        Snapshot.fill(snapshot, bounds, (isDark ? RGBA.white : RGBA(red: 0, green: 0, blue: 0, alpha: 1)).withAlpha(0.12))
        if segments.isEmpty {
            guard let space else { return }
            let used = Double(space.usedBytes) / Double(max(1, space.totalCapacity))
            Snapshot.fill(snapshot, CGRect(x: 0, y: 0, width: width * min(1, used), height: height), Accent.color)
            return
        }
        var x = 0.0
        for segment in segments {
            let segmentWidth = width * segment.fraction
            Snapshot.fill(snapshot, CGRect(x: x, y: 0, width: segmentWidth, height: height), RGBA(segment.rgb))
            x += segmentWidth
        }
    }

    // MARK: - Hover

    private struct Stretch {
        let id: String
        let label: String
        let size: Int64
        let range: ClosedRange<Double>
    }

    /// The segments, then the free track after them, in bar coordinates.
    private func stretches() -> [Stretch] {
        guard !segments.isEmpty else { return [] }
        let width = canvas.width
        var start = 0.0
        var result: [Stretch] = []
        for segment in segments {
            let end = start + width * segment.fraction
            result.append(Stretch(id: segment.id, label: L(segment.label), size: segment.size, range: start...end))
            start = end
        }
        if let space {
            result.append(Stretch(id: Self.freeTrackID, label: L("Available"), size: space.availableCapacity, range: start...max(start, width)))
        }
        return result
    }

    /// Shows the bubble over the stretch under `x`, or, when the segments
    /// change under a stationary pointer, over the stretch with `id`.
    private func hover(at x: Double?, id: String? = nil) {
        let all = stretches()
        let stretch: Stretch? = if let x {
            all.first { x < $0.range.upperBound } ?? all.last
        } else {
            all.first { $0.id == id }
        }
        guard let stretch else {
            hideNow()
            return
        }
        hideTask?.cancel()
        hideTask = nil
        hoveredID = stretch.id
        gtk_label_set_text(ptr(bubbleTitle), stretch.label)
        gtk_label_set_text(ptr(bubbleSize), NeodiskFormatters.size(stretch.size))
        let midX = (stretch.range.lowerBound + stretch.range.upperBound) / 2
        var target = GdkRectangle(x: Int32(midX.rounded()), y: 0, width: 1, height: Int32(Self.height))
        gtk_popover_set_pointing_to(ptr(bubble), &target)
        if gtk_widget_get_visible(ptr(bubble)) == 0 {
            gtk_popover_popup(ptr(bubble))
        }
    }

    /// Leaving closes the bubble after a short grace period, so sliding onto
    /// the next row's bar or back again doesn't flicker it.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            self?.hideNow()
        }
    }

    private func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        hoveredID = nil
        gtk_popover_popdown(ptr(bubble))
    }
}
