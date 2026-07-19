//
//  CushionTreemapRenderer.swift
//  TreemapKit
//
//  Rasterizes treemap cells into RGBA8 pixels with per-pixel cushion shading.
//  The pixel loop (`rasterize`) is portable stdlib SIMD; the CGImage assembly,
//  the `memset_pattern4` background fill, and the Dispatch parallelization are
//  gated so the core is consumable off-platform (e.g. a WebAssembly demo).
//

#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#elseif canImport(Dispatch)
import Foundation  // ProcessInfo for the concurrent chunk count
#endif
#if canImport(Dispatch)
import Dispatch
#endif

public enum CushionTreemapRenderer {
    /// Directional light, image coordinates (y down), pointing from the
    /// surface toward the light: above and to the top-left of the map.
    private nonisolated static let light = normalized(SIMD3<Double>(-0.3, -0.3, 0.906))
    private nonisolated static let ambient = 0.30
    private nonisolated static let diffuse = 0.70

    /// Diagonal hatch baked into cloud-only (`isDataless`) cells: alternating
    /// bands `hatchStripePeriod` device pixels wide along the x+y diagonal,
    /// each band nudged one way or the other by `hatchContrast`. Modulating
    /// symmetrically about the cell's own brightness keeps the stripes visible
    /// on both light and dark fills without shifting hue. The hatch lives in
    /// pixel space, so it tracks gesture zoom through the layer transform and
    /// re-crisps on the next render, exactly like the rest of the raster.
    private nonisolated static let hatchStripePeriod = 4
    private nonisolated static let hatchContrast = 0.14

    /// Portable rasterization: RGBA8 premultipliedLast, one byte-quadruple per
    /// pixel packed little-endian (`R | G<<8 | B<<16 | 0xFF000000`), row stride
    /// `width * 4`, alpha always 255. Cell rects are in view points; the output
    /// covers `bounds` at `scale` (2 for Retina). Callers on a canvas blit the
    /// buffer straight into ImageData; `render` wraps it into a CGImage.
    public nonisolated static func rasterizeRGBA(
        cells: [TreemapCell],
        bounds: CGRect,
        scale: CGFloat,
        background: SIMD3<Float>? = TreemapRasterTarget.backgroundRGB
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        TreemapRasterTarget.rasterizeRGBA(
            bounds: bounds, scale: scale,
            background: TreemapRasterTarget.pattern(for: background)
        ) { base, width, height, bytesPerRow in
            renderCells(
                cells,
                origin: bounds.origin,
                scale: Double(scale),
                into: base,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            )
        }
    }

    #if canImport(CoreGraphics)
    /// Renders `cells` at `scale` into a CGImage (see TreemapRasterTarget for
    /// the buffer contract).
    public nonisolated static func render(
        cells: [TreemapCell],
        bounds: CGRect,
        scale: CGFloat,
        background: SIMD3<Float>? = TreemapRasterTarget.backgroundRGB
    ) -> CGImage? {
        TreemapRasterTarget.render(
            bounds: bounds, scale: scale,
            background: TreemapRasterTarget.pattern(for: background)
        ) { base, width, height, bytesPerRow in
            renderCells(
                cells,
                origin: bounds.origin,
                scale: Double(scale),
                into: base,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            )
        }
    }
    #endif

    /// Rasterizes every cell into the buffer. Cells never overlap, so
    /// concurrent chunks write disjoint pixels; without Dispatch this falls
    /// back to a serial pass.
    private nonisolated static func renderCells(
        _ cells: [TreemapCell],
        origin: CGPoint,
        scale: Double,
        into base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        #if canImport(Dispatch)
        nonisolated(unsafe) let base = base
        let chunkCount = max(1, min(cells.count, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = (cells.count + chunkCount - 1) / max(1, chunkCount)

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
            // With ceil-divided chunks, trailing chunks can start past the
            // end (e.g. 10 cells / 8 cores → chunkSize 2 → chunk 7 starts
            // at 14); start..<end would trap with end < start.
            let start = min(chunkIndex * chunkSize, cells.count)
            let end = min(start + chunkSize, cells.count)
            for index in start..<end {
                rasterize(
                    cell: cells[index],
                    origin: origin,
                    scale: scale,
                    into: base,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
            }
        }
        #else
        for cell in cells {
            rasterize(
                cell: cell,
                origin: origin,
                scale: scale,
                into: base,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            )
        }
        #endif
    }

    private nonisolated static func rasterize(
        cell: TreemapCell,
        origin: CGPoint,
        scale: Double,
        into base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        // Pixel bounds relative to the render origin; consistent rounding on
        // shared edges leaves no gaps.
        let originX = Double(origin.x)
        let originY = Double(origin.y)
        let x0 = max(0, Int(((Double(cell.rect.minX) - originX) * scale).rounded()))
        let x1 = min(width, Int(((Double(cell.rect.maxX) - originX) * scale).rounded()))
        let y0 = max(0, Int(((Double(cell.rect.minY) - originY) * scale).rounded()))
        let y1 = min(height, Int(((Double(cell.rect.maxY) - originY) * scale).rounded()))
        guard x1 > x0, y1 > y0 else { return }

        let surface = cell.surface
        let r = Double(cell.rgb.x)
        let g = Double(cell.rgb.y)
        let b = Double(cell.rgb.z)
        // Cloud-only cells get a diagonal hatch folded into the shade term; a
        // per-cell branch keeps the stripe math off the hot path for the vast
        // majority of cells, which are on-disk.
        let hatch = cell.isDataless

        // SIMD lane constants, hoisted out of the pixel loops. Every vector
        // expression below mirrors the scalar tail's operation tree exactly
        // (same operations, same order), so the two paths agree bit-for-bit.
        let laneCount = 8
        let laneIndices = SIMD8<Double>(0, 1, 2, 3, 4, 5, 6, 7)
        let originXV = SIMD8<Double>(repeating: originX)
        let scaleV = SIMD8<Double>(repeating: scale)
        let xaV = SIMD8<Double>(repeating: surface.xa)
        let xbV = SIMD8<Double>(repeating: surface.xb)
        let lightXV = SIMD8<Double>(repeating: light.x)
        let lightZV = SIMD8<Double>(repeating: light.z)
        let ambientV = SIMD8<Double>(repeating: ambient)
        let diffuseV = SIMD8<Double>(repeating: diffuse)
        let rV = SIMD8<Double>(repeating: r)
        let gV = SIMD8<Double>(repeating: g)
        let bV = SIMD8<Double>(repeating: b)
        let halfV = SIMD8<Double>(repeating: 0.5)
        let oneV = SIMD8<Double>(repeating: 1)
        let scale255V = SIMD8<Double>(repeating: 255)
        let zeroV = SIMD8<Double>()
        let alphaV = SIMD8<UInt32>(repeating: 255 &<< 24)
        let twoV = SIMD8<Double>(repeating: 2)
        let hatchPeriodV = SIMD8<Double>(repeating: Double(hatchStripePeriod))
        let hatchHighV = SIMD8<Double>(repeating: 1 + hatchContrast)
        let hatchSpanV = SIMD8<Double>(repeating: 2 * hatchContrast)

        for py in y0..<y1 {
            // Sample the surface at the pixel center, in view coordinates.
            let yCenter = originY + (Double(py) + 0.5) / scale
            let gy = surface.ya + surface.yb * yCenter
            // Per-row constants: gy·gy and gy·light.y are reused unchanged by
            // every lane, matching the scalar `gy * gy` / `gy * light.y`.
            let gySquaredV = SIMD8<Double>(repeating: gy * gy)
            let gyLightYV = SIMD8<Double>(repeating: gy * light.y)
            let hatchRowV = SIMD8<Double>(repeating: Double(py))
            var offset = py * bytesPerRow + x0 * 4
            var px = x0

            // Vector body: 8 pixels per iteration.
            while px + laneCount <= x1 {
                let pxV = SIMD8<Double>(repeating: Double(px)) + laneIndices
                let xCenter = originXV + (pxV + halfV) / scaleV
                let gx = xaV + xbV * xCenter

                // Surface normal is (-gx, -gy, 1) (unnormalized).
                let normalLength = (gx * gx + gySquaredV + oneV).squareRoot()
                let dot = (-gx * lightXV - gyLightYV + lightZV) / normalLength
                var shade = ambientV + diffuseV * pointwiseMax(zeroV, dot)
                if hatch {
                    // stripe = floor((px + py) / period); parity 0/1 = stripe
                    // mod 2. Pixel indices are exact integers well within
                    // double range, so this matches the scalar-tail integer
                    // math bit-for-bit and leaves no seam at the body boundary.
                    let stripe = floorV((pxV + hatchRowV) / hatchPeriodV)
                    let parity = stripe - twoV * floorV(stripe * halfV)
                    shade = shade * (hatchHighV - hatchSpanV * parity)
                }

                // Clamp to [0, 255] and truncate toward zero, exactly like the
                // scalar `UInt8(min(255, max(0, …)))`.
                let red = truncateToU32(pointwiseMin(scale255V, pointwiseMax(zeroV, rV * shade * scale255V)))
                let green = truncateToU32(pointwiseMin(scale255V, pointwiseMax(zeroV, gV * shade * scale255V)))
                let blue = truncateToU32(pointwiseMin(scale255V, pointwiseMax(zeroV, bV * shade * scale255V)))
                // Pack RGBA little-endian into one 32-bit word per pixel and
                // store all 8 pixels with a single unaligned vector store.
                let pixels = red | (green &<< 8) | (blue &<< 16) | alphaV
                UnsafeMutableRawPointer(base + offset)
                    .storeBytes(of: pixels, toByteOffset: 0, as: SIMD8<UInt32>.self)
                offset += laneCount * 4
                px += laneCount
            }

            // Scalar tail for the last (x1 - px) < 8 pixels.
            while px < x1 {
                let xCenter = originX + (Double(px) + 0.5) / scale
                let gx = surface.xa + surface.xb * xCenter

                // Surface normal is (-gx, -gy, 1) (unnormalized).
                let normalLength = (gx * gx + gy * gy + 1).squareRoot()
                let dot = (-gx * light.x - gy * light.y + light.z) / normalLength
                var shade = ambient + diffuse * max(0, dot)
                if hatch {
                    let parity = ((px + py) / hatchStripePeriod) & 1
                    shade *= (1 + hatchContrast) - (2 * hatchContrast) * Double(parity)
                }

                base[offset] = UInt8(min(255, max(0, r * shade * 255)))
                base[offset + 1] = UInt8(min(255, max(0, g * shade * 255)))
                base[offset + 2] = UInt8(min(255, max(0, b * shade * 255)))
                base[offset + 3] = 255
                offset += 4
                px += 1
            }
        }
    }

    /// Truncates non-negative doubles in [0, 2^31) toward zero, per lane —
    /// identical to `UInt32(d)` but branch-free so it compiles to vector
    /// instructions. `UInt32.init(_: Double)` carries trap checks per lane and
    /// `SIMD8<UInt32>.init(_:rounding:)` goes through an unspecialized generic
    /// path; both measured an order of magnitude slower.
    ///
    /// Adding 2^52 pushes the integer part into the low mantissa bits
    /// (round-to-nearest-even); subtracting it back yields round(d), then one
    /// is subtracted from lanes that rounded up to recover floor(d). Re-adding
    /// 2^52 to the now-integral value leaves the integer in the low 32 bits of
    /// the bit pattern.
    private nonisolated static func truncateToU32(_ d: SIMD8<Double>) -> SIMD8<UInt32> {
        let magic = SIMD8<Double>(repeating: 0x1.0p52)
        let rounded = (d + magic) - magic
        let floored = rounded.replacing(with: rounded - 1, where: rounded .> d)
        let bits = unsafeBitCast(floored + magic, to: SIMD8<UInt64>.self)
        return SIMD8<UInt32>(truncatingIfNeeded: bits)
    }

    /// Per-lane `floor` for magnitudes below 2^52, via the same round-trip the
    /// truncation helper uses: adding then subtracting 2^52 snaps to the
    /// nearest integer, and lanes that rounded up are stepped back down.
    private nonisolated static func floorV(_ d: SIMD8<Double>) -> SIMD8<Double> {
        let magic = SIMD8<Double>(repeating: 0x1.0p52)
        let rounded = (d + magic) - magic
        return rounded.replacing(with: rounded - 1, where: rounded .> d)
    }

    private nonisolated static func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return SIMD3(v.x / length, v.y / length, v.z / length)
    }
}
