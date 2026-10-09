//
//  Drawing.swift
//  NeodiskGTK
//
//  GtkSnapshot helpers in Neodisk's vocabulary: rectangles in points, colors
//  as the shared model's sRGB SIMD3<Float> triples, rasters as the
//  premultiplied RGBA8 buffers TreemapKit produces.
//

import CGtk
import Foundation

struct RGBA: Equatable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float = 1

    init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ rgb: SIMD3<Float>, alpha: Float = 1) {
        self.init(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: alpha)
    }

    static let white = RGBA(red: 1, green: 1, blue: 1)
    static let black = RGBA(red: 0, green: 0, blue: 0)

    func withAlpha(_ alpha: Float) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    var gdk: GdkRGBA {
        GdkRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Relative luminance (sRGB approximation) for picking legible text.
    var luminance: Float {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

func grapheneRect(_ rect: CGRect) -> graphene_rect_t {
    graphene_rect_t(
        origin: graphene_point_t(x: Float(rect.minX), y: Float(rect.minY)),
        size: graphene_size_t(width: Float(rect.width), height: Float(rect.height))
    )
}

@MainActor
enum Snapshot {
    static func fill(_ snapshot: GPtr, _ rect: CGRect, _ color: RGBA) {
        var bounds = grapheneRect(rect)
        var gdkColor = color.gdk
        gtk_snapshot_append_color(ptr(snapshot), &gdkColor, &bounds)
    }

    /// A stroke of `width` points drawn inside `rect`.
    static func stroke(_ snapshot: GPtr, _ rect: CGRect, width: Float, _ color: RGBA, cornerRadius: Float = 0) {
        var bounds = grapheneRect(rect)
        var rounded = GskRoundedRect()
        gsk_rounded_rect_init_from_rect(&rounded, &bounds, cornerRadius)
        var widths: (Float, Float, Float, Float) = (width, width, width, width)
        let gdkColor = color.gdk
        var colors: (GdkRGBA, GdkRGBA, GdkRGBA, GdkRGBA) = (gdkColor, gdkColor, gdkColor, gdkColor)
        withUnsafePointer(to: &widths) { widthPointer in
            withUnsafePointer(to: &colors) { colorPointer in
                widthPointer.withMemoryRebound(to: Float.self, capacity: 4) { widthArray in
                    colorPointer.withMemoryRebound(to: GdkRGBA.self, capacity: 4) { colorArray in
                        gtk_snapshot_append_border(ptr(snapshot), &rounded, widthArray, colorArray)
                    }
                }
            }
        }
    }

    static func texture(_ snapshot: GPtr, _ texture: GPtr, in rect: CGRect) {
        var bounds = grapheneRect(rect)
        gtk_snapshot_append_texture(ptr(snapshot), ptr(texture), &bounds)
    }

    static func pushClip(_ snapshot: GPtr, _ rect: CGRect) {
        var bounds = grapheneRect(rect)
        gtk_snapshot_push_clip(ptr(snapshot), &bounds)
    }

    static func pop(_ snapshot: GPtr) {
        gtk_snapshot_pop(ptr(snapshot))
    }

    /// Draws a laid-out Pango text block with its top-left at `origin`.
    static func layout(_ snapshot: GPtr, _ layout: GPtr, at origin: CGPoint, _ color: RGBA) {
        gtk_snapshot_save(ptr(snapshot))
        var point = graphene_point_t(x: Float(origin.x), y: Float(origin.y))
        gtk_snapshot_translate(ptr(snapshot), &point)
        var gdkColor = color.gdk
        gtk_snapshot_append_layout(ptr(snapshot), ptr(layout), &gdkColor)
        gtk_snapshot_restore(ptr(snapshot))
    }

    /// Opens a cairo context over `rect` for vector drawing GtkSnapshot has
    /// no node for. The caller must `cairo_destroy` it.
    static func cairo(_ snapshot: GPtr, _ rect: CGRect) -> OpaquePointer? {
        var bounds = grapheneRect(rect)
        return gtk_snapshot_append_cairo(ptr(snapshot), &bounds)
    }
}

/// A GdkTexture over premultiplied RGBA8 pixels (TreemapKit's raster
/// format), uploaded once and drawn by the GPU renderer every frame.
@MainActor
func makeTexture(rgba pixels: [UInt8], width: Int, height: Int) -> GObjectRef? {
    guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
    let bytes = pixels.withUnsafeBytes { buffer in
        g_bytes_new(buffer.baseAddress, gsize(buffer.count))
    }
    defer { g_bytes_unref(bytes) }
    guard let texture = gdk_memory_texture_new(
        Int32(width), Int32(height), GDK_MEMORY_R8G8B8A8_PREMULTIPLIED, bytes, gsize(width * 4)
    ) else { return nil }
    return GObjectRef(adopting: raw(texture)!)
}

/// A GdkTexture over a cairo ARGB32 image surface's pixels (premultiplied
/// B,G,R,A bytes on little-endian machines).
@MainActor
func makeTexture(cairoSurface surface: OpaquePointer?) -> GObjectRef? {
    guard let surface else { return nil }
    cairo_surface_flush(surface)
    let width = Int(cairo_image_surface_get_width(surface))
    let height = Int(cairo_image_surface_get_height(surface))
    let stride = Int(cairo_image_surface_get_stride(surface))
    guard width > 0, height > 0, let data = cairo_image_surface_get_data(surface) else { return nil }
    let bytes = g_bytes_new(data, gsize(stride * height))
    defer { g_bytes_unref(bytes) }
    guard let texture = gdk_memory_texture_new(
        Int32(width), Int32(height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride)
    ) else { return nil }
    return GObjectRef(adopting: raw(texture)!)
}

// MARK: - Text

@MainActor
enum Text {
    /// A Pango layout for `text` in `widget`'s font, ellipsized to
    /// `maxWidth` points when given.
    static func layout(
        _ text: String,
        in widget: GPtr,
        maxWidth: Double? = nil,
        bold: Bool = false,
        scale: Double = 1
    ) -> GObjectRef? {
        guard let layout = gtk_widget_create_pango_layout(ptr(widget), text) else { return nil }
        let reference = GObjectRef(adopting: raw(layout)!)
        if let maxWidth {
            pango_layout_set_width(layout, Int32(maxWidth * Double(neodisk_pango_scale())))
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            pango_layout_set_single_paragraph_mode(layout, gbool(true))
        }
        if bold || scale != 1 {
            let context = pango_layout_get_context(layout)
            let base = pango_font_description_copy(pango_context_get_font_description(context))
            if bold {
                pango_font_description_set_weight(base, PANGO_WEIGHT_BOLD)
            }
            if scale != 1 {
                let size = pango_font_description_get_size(base)
                pango_font_description_set_size(base, Int32(Double(size) * scale))
            }
            pango_layout_set_font_description(layout, base)
            pango_font_description_free(base)
        }
        return reference
    }

    static func size(of layout: GPtr) -> CGSize {
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(ptr(layout), &width, &height)
        return CGSize(width: Double(width), height: Double(height))
    }
}
