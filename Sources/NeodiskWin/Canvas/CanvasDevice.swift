// Swift ownership over CNeodiskCanvas: a Direct2D surface (window or offscreen), device images, and DirectWrite
// text layouts. Coordinates are DIPs (view points); images are device pixels drawn at the canvas DPI.

import CNeodiskCanvas
import Foundation
import WinSDK

extension NDColor {
    init(_ rgb: SIMD3<Float>, alpha: Float = 1) {
        self.init(r: rgb.x, g: rgb.y, b: rgb.z, a: alpha)
    }

    init(_ rgba: SIMD4<Float>) {
        self.init(r: rgba.x, g: rgba.y, b: rgba.z, a: rgba.w)
    }

    static let white = NDColor(r: 1, g: 1, b: 1, a: 1)
    static let black = NDColor(r: 0, g: 0, b: 0, a: 1)
    static let clear = NDColor(r: 0, g: 0, b: 0, a: 0)

    func withAlpha(_ alpha: Float) -> NDColor {
        NDColor(r: r, g: g, b: b, a: alpha)
    }
}

extension NDRect {
    init(_ rect: CGRect) {
        self.init(x: Float(rect.minX), y: Float(rect.minY), width: Float(rect.width), height: Float(rect.height))
    }
}

/// A bitmap on the shared device, drawable by any canvas.
final class CanvasImage {
    let pointer: OpaquePointer
    let pixelWidth: Int
    let pixelHeight: Int

    init(adopting pointer: OpaquePointer, pixelWidth: Int, pixelHeight: Int) {
        self.pointer = pointer
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    deinit {
        ndc_image_release(pointer)
    }

    var byteCount: Int { pixelWidth * pixelHeight * 4 }
}

/// A single-line DirectWrite layout. Built on any thread, drawn on the canvas's.
final class CanvasText: @unchecked Sendable {
    let pointer: OpaquePointer
    let width: Double
    let height: Double
    let naturalWidth: Double

    enum Alignment: Int32 {
        case leading = 0
        case center = 1
        case trailing = 2
    }

    /// Ellipsized at `maxWidth` DIPs when given.
    init?(_ string: String, size: Double, bold: Bool = false, maxWidth: Double? = nil, alignment: Alignment = .leading) {
        let utf16 = Array(string.utf16)
        guard let pointer = ndc_text_create(
            utf16, UInt32(utf16.count), Float(size), bold ? 1 : 0, Float(maxWidth ?? 0), alignment.rawValue
        ) else { return nil }
        self.pointer = pointer
        var width: Float = 0
        var height: Float = 0
        var natural: Float = 0
        ndc_text_metrics(pointer, &width, &height, &natural)
        self.width = Double(width)
        self.height = Double(height)
        self.naturalWidth = Double(natural)
    }

    deinit {
        ndc_text_release(pointer)
    }

    var isTruncated: Bool { naturalWidth > width + 0.5 }

    static func measure(_ string: String, size: Double, bold: Bool = false) -> Double {
        let utf16 = Array(string.utf16)
        return Double(ndc_text_measure(utf16, UInt32(utf16.count), Float(size), bold ? 1 : 0))
    }
}

/// A Direct2D surface: a window's swap chain, or an offscreen bitmap for headless renders.
@MainActor
final class D2DCanvas {
    private(set) var pointer: OpaquePointer
    let isOffscreen: Bool
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int
    private(set) var dpi: Float

    private init(pointer: OpaquePointer, isOffscreen: Bool, pixelWidth: Int, pixelHeight: Int, dpi: Float) {
        self.pointer = pointer
        self.isOffscreen = isOffscreen
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dpi = dpi
    }

    static func forWindow(_ hwnd: HWND, pixelWidth: Int, pixelHeight: Int, dpi: Float) -> D2DCanvas? {
        var canvas: OpaquePointer?
        let hr = ndc_canvas_create_hwnd(
            UnsafeMutableRawPointer(hwnd), UInt32(max(pixelWidth, 1)), UInt32(max(pixelHeight, 1)), dpi, &canvas
        )
        guard hr >= 0, let canvas else {
            CanvasLog.write("canvas: swap chain creation failed hr=0x\(String(UInt32(bitPattern: hr), radix: 16))")
            return nil
        }
        return D2DCanvas(pointer: canvas, isOffscreen: false, pixelWidth: pixelWidth, pixelHeight: pixelHeight, dpi: dpi)
    }

    static func offscreen(pixelWidth: Int, pixelHeight: Int, dpi: Float) -> D2DCanvas? {
        var canvas: OpaquePointer?
        let hr = ndc_canvas_create_offscreen(UInt32(max(pixelWidth, 1)), UInt32(max(pixelHeight, 1)), dpi, &canvas)
        guard hr >= 0, let canvas else {
            CanvasLog.write("canvas: offscreen creation failed hr=0x\(String(UInt32(bitPattern: hr), radix: 16))")
            return nil
        }
        return D2DCanvas(pointer: canvas, isOffscreen: true, pixelWidth: pixelWidth, pixelHeight: pixelHeight, dpi: dpi)
    }

    isolated deinit {
        ndc_canvas_destroy(pointer)
    }

    var scale: Double { Double(dpi) / 96 }

    @discardableResult
    func resize(pixelWidth: Int, pixelHeight: Int, dpi: Float) -> Bool {
        guard pixelWidth != self.pixelWidth || pixelHeight != self.pixelHeight || dpi != self.dpi else { return true }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dpi = dpi
        return ndc_canvas_resize(pointer, UInt32(max(pixelWidth, 1)), UInt32(max(pixelHeight, 1)), dpi) >= 0
    }

    func begin(clear: NDColor) -> Bool {
        ndc_canvas_begin(pointer, clear) >= 0
    }

    enum Present: Int32 {
        case none = 0
        case vsync = 1
        case immediate = 2
    }

    /// False when the device was lost: the caller drops every image and builds a new canvas.
    func end(present: Present) -> Bool {
        let hr = ndc_canvas_end(pointer, present.rawValue)
        return hr != ND_DEVICE_LOST
    }

    func finish() {
        ndc_canvas_finish(pointer)
    }

    func savePNG(to path: String) -> Bool {
        let utf16 = Array(path.utf16) + [0]
        return ndc_canvas_save_png(pointer, utf16) >= 0
    }

    // MARK: Drawing

    func draw(_ image: CanvasImage, in rect: CGRect, opacity: Float = 1, smooth: Bool) {
        ndc_draw_image(pointer, image.pointer, NDRect(rect), opacity, smooth ? 1 : 0)
    }

    func fill(_ rect: CGRect, _ color: NDColor) {
        ndc_fill_rect(pointer, NDRect(rect), color)
    }

    /// A stroke of `width` inside `rect`.
    func stroke(_ rect: CGRect, width: Float, _ color: NDColor) {
        ndc_stroke_rect(pointer, NDRect(rect), width, color)
    }

    func pushClip(_ rect: CGRect) {
        ndc_push_clip(pointer, NDRect(rect))
    }

    func popClip() {
        ndc_pop_clip(pointer)
    }

    func draw(_ text: CanvasText, at origin: CGPoint, _ color: NDColor) {
        ndc_draw_text(pointer, text.pointer, Float(origin.x), Float(origin.y), color)
    }

    func drawArcs(center: CGPoint, _ arcs: [NDArc], opacities: [Float]?, separator: NDColor, width: Float) {
        guard !arcs.isEmpty else { return }
        arcs.withUnsafeBufferPointer { arcBuffer in
            if let opacities {
                opacities.withUnsafeBufferPointer { opacityBuffer in
                    ndc_draw_arcs(pointer, Float(center.x), Float(center.y), arcBuffer.baseAddress, UInt32(arcs.count),
                                  opacityBuffer.baseAddress, separator, width)
                }
            } else {
                ndc_draw_arcs(pointer, Float(center.x), Float(center.y), arcBuffer.baseAddress, UInt32(arcs.count),
                              nil, separator, width)
            }
        }
    }

    func drawArcOverlay(center: CGPoint, _ arc: NDArc, stroke: NDColor, width: Float) {
        ndc_draw_arc_overlay(pointer, Float(center.x), Float(center.y), arc, stroke, width)
    }

    // MARK: Images

    /// Premultiplied pixels, RGBA (TreemapKit's raster) or BGRA.
    func makeImage(pixels: [UInt8], width: Int, height: Int, stride: Int, isBGRA: Bool) -> CanvasImage? {
        guard width > 0, height > 0, pixels.count >= stride * height else { return nil }
        let image = pixels.withUnsafeBytes { buffer in
            ndc_image_create(pointer, buffer.baseAddress, UInt32(width), UInt32(height), UInt32(stride), isBGRA ? 1 : 0)
        }
        return image.map { CanvasImage(adopting: $0, pixelWidth: width, pixelHeight: height) }
    }

    /// Text laid out once into a transparent image covering the canvas, with a dark halo when `halo` is set.
    func renderTexts(
        _ texts: [(text: CanvasText, origin: CGPoint)],
        color: NDColor,
        halo: (radius: Float, color: NDColor)?
    ) -> CanvasImage? {
        guard !texts.isEmpty else { return nil }
        let pointers: [OpaquePointer?] = texts.map { $0.text.pointer }
        let origins: [Float] = texts.flatMap { [Float($0.origin.x), Float($0.origin.y)] }
        let image = pointers.withUnsafeBufferPointer { pointerBuffer in
            origins.withUnsafeBufferPointer { originBuffer in
                ndc_image_render_texts(
                    pointer, UInt32(pixelWidth), UInt32(pixelHeight), pointerBuffer.baseAddress, originBuffer.baseAddress,
                    UInt32(texts.count), color, halo?.radius ?? 0, halo?.color ?? .clear
                )
            }
        }
        return withExtendedLifetime(texts) {
            image.map { CanvasImage(adopting: $0, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
        }
    }

    static var adapterDescription: (name: String, isSoftware: Bool) {
        var info = NDAdapterInfo()
        ndc_adapter_info(&info)
        let name = withUnsafeBytes(of: info.description) { raw -> String in
            let units = raw.bindMemory(to: UInt16.self)
            let length = units.firstIndex(of: 0) ?? units.count
            return String(decoding: units[..<length], as: UTF16.self)
        }
        return (name, info.isSoftware != 0)
    }
}

/// Diagnostics on stderr (and a file when NEODISK_CANVAS_LOG is set), for runs without a console.
enum CanvasLog {
    nonisolated(unsafe) private static var handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["NEODISK_CANVAS_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static let lock = NSLock()

    static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data((line + "\n").utf8)
        FileHandle.standardError.write(data)
        handle?.write(data)
    }
}
