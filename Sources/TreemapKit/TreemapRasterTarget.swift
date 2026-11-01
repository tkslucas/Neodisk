// Shared RGBA8 buffer plumbing for the rasterizers. CGImage assembly and Dispatch are gated so the core
// builds off-platform (a WebAssembly demo).

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Foundation)
import Foundation
#endif
#if canImport(Dispatch)
import Dispatch
#endif

public enum TreemapRasterTarget {
    /// Fallback for headless renders and tests (the app passes the window background). Dark, so skipped
    /// sub-pixel cells read as seams rather than holes.
    static let backgroundPattern: [UInt8] = [18, 18, 22, 255]

    /// Public so translucent flat fills composite against the same color the raster clears to.
    public nonisolated static let backgroundRGB = SIMD3<Float>(18, 18, 22) / 255

    /// nil clears to transparent: the app composites over the live window backdrop, since an opaque guess
    /// can never match the desktop-tinted backdrop on screen.
    nonisolated static func pattern(for rgb: SIMD3<Float>?) -> [UInt8] {
        guard let rgb else { return [0, 0, 0, 0] }
        return [
            UInt8(min(255, max(0, rgb.x * 255))),
            UInt8(min(255, max(0, rgb.y * 255))),
            UInt8(min(255, max(0, rgb.z * 255))),
            255,
        ]
    }

    /// RGBA8 premultipliedLast, row stride `width * 4`, alpha always 255; `draw` gets a buffer prefilled with
    /// `background`.
    static func rasterizeRGBA(
        bounds: CGRect,
        scale: CGFloat,
        background: [UInt8] = backgroundPattern,
        draw: (_ base: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int, _ bytesPerRow: Int) -> Void
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        // Uninitialized: the background fill writes every byte, so zeroing first would touch it all twice.
        let pixels = [UInt8](unsafeUninitializedCapacity: byteCount) { buffer, initializedCount in
            guard let base = buffer.baseAddress else { return }
            fillBackground(base, width: width, height: height, pattern: background)
            draw(base, width, height, bytesPerRow)
            initializedCount = byteCount
        }
        return (pixels, width, height)
    }

    #if canImport(CoreGraphics)
    /// Draws into a CFData the provider retains without copying; a `[UInt8]` would copy ~25 MB per render.
    static func render(
        bounds: CGRect,
        scale: CGFloat,
        background: [UInt8] = backgroundPattern,
        draw: (_ base: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int, _ bytesPerRow: Int) -> Void
    ) -> CGImage? {
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        guard let pixelData = CFDataCreateMutable(kCFAllocatorDefault, byteCount) else { return nil }
        CFDataSetLength(pixelData, byteCount)
        guard let rawBase = CFDataGetMutableBytePtr(pixelData) else { return nil }

        fillBackground(rawBase, width: width, height: height, pattern: background)
        draw(rawBase, width, height, bytesPerRow)

        // The pixels are sRGB; an untagged or device-RGB image skips color matching on wide-gamut displays
        // and shifts the map off the window background it must blend into.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixelData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    #endif

    /// Prefills the buffer with the background pattern, a band of rows per task: a 4K canvas is 64 MB, more
    /// than one core's store bandwidth.
    static func fillBackground(
        _ base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        pattern: [UInt8] = backgroundPattern
    ) {
        let word = UInt32(pattern[0]) | UInt32(pattern[1]) << 8 | UInt32(pattern[2]) << 16 | UInt32(pattern[3]) << 24
        nonisolated(unsafe) let base = base
        forEachRowBand(height: height) { rows in
            let start = base + rows.lowerBound * width * 4
            let count = rows.count * width
            start.withMemoryRebound(to: UInt32.self, capacity: count) {
                $0.initialize(repeating: word, count: count)
            }
        }
    }

    /// Runs `body` over disjoint row bands, concurrently where Dispatch exists. Each band draws every cell
    /// clipped to its rows, so draw order holds within a band and bands never share a pixel.
    static func forEachRowBand(height: Int, _ body: @Sendable (Range<Int>) -> Void) {
        #if canImport(Dispatch)
        // Several bands per core: a band crossing one big cell costs more than one full of slivers.
        let bandCount = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            body((height * band / bandCount)..<(height * (band + 1) / bandCount))
        }
        #else
        body(0..<height)
        #endif
    }
}
