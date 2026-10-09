//
//  Canvas.swift
//  NeodiskGTK
//
//  A GtkWidget subclass whose drawing belongs to Swift: "NeodiskCanvas"
//  overrides the snapshot and size_allocate vfuncs and forwards them to a
//  delegate. Drawing through GtkSnapshot (textures, color and border nodes,
//  Pango layouts) keeps the treemap and sunburst on GTK's GPU renderer — a
//  GtkDrawingArea would re-rasterize and re-upload a full-window cairo
//  surface on every hover.
//

import CGtk

@MainActor
protocol CanvasDelegate: AnyObject {
    /// Draw into `snapshot`, a GtkSnapshot, covering width × height points.
    func canvas(_ canvas: Canvas, snapshot: GPtr, width: Double, height: Double)
    /// The canvas got a new allocation.
    func canvas(_ canvas: Canvas, didResizeTo width: Int, height: Int)
}

@MainActor
final class Canvas {
    let widget: GPtr
    weak var delegate: CanvasDelegate?

    private static let dataKey = "neodisk-canvas"

    private static let type: GType = {
        var info = GTypeInfo()
        info.class_size = guint16(MemoryLayout<GtkWidgetClass>.size)
        info.instance_size = guint16(MemoryLayout<GtkWidget>.size)
        info.class_init = { classPointer, _ in
            guard let widgetClass = classPointer?.assumingMemoryBound(to: GtkWidgetClass.self) else { return }
            widgetClass.pointee.snapshot = { widget, snapshot in
                nonisolated(unsafe) let widget = widget
                nonisolated(unsafe) let snapshot = snapshot
                MainActor.assumeIsolated {
                    guard let canvas = Canvas.from(raw(widget)), let snapshot = raw(snapshot) else { return }
                    canvas.delegate?.canvas(
                        canvas,
                        snapshot: snapshot,
                        width: Double(gtk_widget_get_width(widget)),
                        height: Double(gtk_widget_get_height(widget))
                    )
                }
            }
            widgetClass.pointee.size_allocate = { widget, width, height, _ in
                nonisolated(unsafe) let widget = widget
                MainActor.assumeIsolated {
                    guard let canvas = Canvas.from(raw(widget)) else { return }
                    canvas.delegate?.canvas(canvas, didResizeTo: Int(width), height: Int(height))
                }
            }
        }
        return g_type_register_static(gtk_widget_get_type(), "NeodiskCanvas", &info, GTypeFlags(rawValue: 0))
    }()

    init() {
        widget = GPtr(g_object_new_with_properties(Self.type, 0, nil, nil))!
        gtk_widget_set_hexpand(ptr(widget), gbool(true))
        gtk_widget_set_vexpand(ptr(widget), gbool(true))
        gtk_widget_set_focusable(ptr(widget), gbool(true))
        attach(self, to: widget, key: Self.dataKey)
    }

    static func from(_ widget: GPtr?) -> Canvas? {
        attached(Canvas.self, to: widget, key: dataKey)
    }

    func queueDraw() {
        gtk_widget_queue_draw(ptr(widget))
    }

    var width: Double { Double(gtk_widget_get_width(ptr(widget))) }
    var height: Double { Double(gtk_widget_get_height(ptr(widget))) }

    /// Device pixels per point for crisp rasters on HiDPI outputs.
    var scaleFactor: Double {
        Double(max(1, gtk_widget_get_scale_factor(ptr(widget))))
    }
}
