//
//  ColorSwatch.swift
//  NeodiskGTK
//
//  A small rounded color chip — the kind and age legends' swatches and the
//  status bar's. Drawn on a canvas, so recoloring is a redraw rather than a
//  style-sheet change.
//

import CGtk
import Foundation

@MainActor
final class ColorSwatch: CanvasDelegate {
    var widget: GPtr { canvas.widget }
    private let canvas = Canvas()

    var rgb: SIMD3<Float>? {
        didSet {
            guard rgb != oldValue else { return }
            Widgets.setVisible(canvas.widget, rgb != nil)
            canvas.queueDraw()
        }
    }

    init(size: Int = 12, rgb: SIMD3<Float>? = nil) {
        self.rgb = rgb
        canvas.delegate = self
        gtk_widget_set_hexpand(ptr(canvas.widget), gbool(false))
        gtk_widget_set_vexpand(ptr(canvas.widget), gbool(false))
        gtk_widget_set_focusable(ptr(canvas.widget), gbool(false))
        gtk_widget_set_size_request(ptr(canvas.widget), Int32(size), Int32(size))
        gtk_widget_set_valign(ptr(canvas.widget), GTK_ALIGN_CENTER)
        Widgets.setVisible(canvas.widget, rgb != nil)
    }

    func canvas(_ canvas: Canvas, didResizeTo width: Int, height: Int) {}

    func canvas(_ canvas: Canvas, snapshot: GPtr, width: Double, height: Double) {
        guard let rgb else { return }
        let side = min(width, height)
        let rect = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        var bounds = grapheneRect(rect)
        var rounded = GskRoundedRect()
        gsk_rounded_rect_init_from_rect(&rounded, &bounds, Float(side / 4))
        gtk_snapshot_push_rounded_clip(ptr(snapshot), &rounded)
        Snapshot.fill(snapshot, rect, RGBA(rgb))
        gtk_snapshot_pop(ptr(snapshot))
    }
}
