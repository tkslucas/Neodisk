//
//  TreemapRasterTarget.swift
//  TreemapKit
//
//  Shared pixel-buffer plumbing for the treemap rasterizers: allocates the
//  RGBA8 buffer, prefills the background, and hands the raw pointer to a
//  renderer's draw pass. The CGImage assembly and the `memset_pattern4`
//  background fill are gated so the core is consumable off-platform
//  (e.g. a WebAssembly demo), same as the renderers themselves.
//

#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#endif

public enum TreemapRasterTarget {
    /// Fallback background for headless renders and tests; the app passes
    /// the window background instead, so the map sits on the same surface
    /// as the rest of the pane in both styles. Dark, so sub-pixel cells
    /// that get skipped read as seams rather than holes. RGBA, straight
    /// (alpha 255).
    static let backgroundPattern: [UInt8] = [18, 18, 22, 255]

    /// `backgroundPattern` as linear RGB, public so scenes and renderers
    /// share one fallback color (translucent flat fills composite against
    /// the same color the raster clears to).
    public nonisolated static let backgroundRGB = SIMD3<Float>(18, 18, 22) / 255

    /// A caller-provided background as the raster's RGBA clear pattern.
    nonisolated static func pattern(for rgb: SIMD3<Float>) -> [UInt8] {
        [
            UInt8(min(255, max(0, rgb.x * 255))),
            UInt8(min(255, max(0, rgb.y * 255))),
            UInt8(min(255, max(0, rgb.z * 255))),
            255,
        ]
    }

    /// Portable rasterization: RGBA8 premultipliedLast, one byte-quadruple
    /// per pixel packed little-endian, row stride `width * 4`, alpha always
    /// 255. The output covers `bounds` at `scale` (2 for Retina); `draw`
    /// receives the buffer prefilled with `background` and writes the cells.
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
    /// Same pixels as `rasterizeRGBA`, but drawn directly into a CFData the
    /// CGImage's data provider retains without copying — a plain `[UInt8]`
    /// would cost a full-buffer copy (~25 MB at 2× on a large window) on
    /// every render.
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

        // The pixel values are sRGB (the app resolves the window background
        // through the sRGB space and the palettes are authored against it).
        // Tag the image accordingly: an untagged/device-RGB image skips color
        // matching on wide-gamut displays, shifting the whole map visibly
        // off the real window background it must blend into.
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
