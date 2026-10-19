// Shared RGBA8 buffer plumbing for the rasterizers. CGImage assembly and `memset_pattern4` are gated
// so the core builds off-platform (a WebAssembly demo).

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Foundation)
import Foundation
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
        var pixels = [UInt8](repeating: 0, count: byteCount)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            fillBackground(base, byteCount: byteCount, pattern: background)
            draw(base, width, height, bytesPerRow)
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

        fillBackground(rawBase, byteCount: byteCount, pattern: background)
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

    /// Prefills the buffer with the background pattern. `memset_pattern4` is
    /// a Darwin libc primitive; elsewhere a 4-byte stride loop does the same.
    static func fillBackground(
        _ base: UnsafeMutablePointer<UInt8>,
        byteCount: Int,
        pattern: [UInt8] = backgroundPattern
    ) {
        #if canImport(Darwin)
        var pattern = pattern
        memset_pattern4(base, &pattern, byteCount)
        #else
        let (b0, b1, b2, b3) = (
            pattern[0], pattern[1],
            pattern[2], pattern[3]
        )
        var offset = 0
        while offset < byteCount {
            base[offset] = b0
            base[offset + 1] = b1
            base[offset + 2] = b2
            base[offset + 3] = b3
            offset += 4
        }
        #endif
    }
}
