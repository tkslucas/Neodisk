//
//  FlatTreemapRenderer.swift
//  TreemapKit
//
//  Rasterizes treemap cells in the flat nested-box style:
//  uniform fills with a soft darkened border per tile, folder
//  containers drawn first so their children overdraw the content region
//  and leave the header strip and inset frame visible. Cells overlap
//  (ancestors under descendants), so unlike the cushion path the draw
//  order matters and the pass is serial — plain row fills are cheap
//  enough that it stays far off the felt-time path. Rounded corners are
//  anti-aliased by per-pixel coverage against whatever was drawn
//  underneath (the parent's fill or the background); everything else is
//  straight memset runs.
//

#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#endif

public enum FlatTreemapRenderer {
    /// Border color: the cell's own fill mixed toward black by this
    /// fraction (equivalent to a black stroke at 0.30 opacity), so the grid reads
    /// in every color mode without introducing a new color channel.
    private nonisolated static let borderShade: Float = 0.70
    /// The border's outermost device-pixel ring blends over whatever lies
    /// beneath at this coverage, and its innermost ring mixes halfway
    /// toward the fill — the soft edges of an anti-aliased vector stroke.
    /// A hard-edged solid band of the same color reads darker and sharper
    /// than intended.
    private nonisolated static let borderEdgeFeather: Double = 0.6
    /// Border thickness in view points (scaled to device pixels).
    private nonisolated static let borderWidth: CGFloat = 1
    /// Every tile draws inset by this much per side, so siblings get a
    /// visible gap and the parent container's fill (drawn first) shows
    /// through as the mat between them. Both the gap and the corner radius
    /// scale DOWN with the tile (fractions of its short side, capped at
    /// these maxima): a constant radius turns small
    /// tiles into pills, and a constant gap eats them.
    private nonisolated static let maxDisplayInset: CGFloat = 0.75
    private nonisolated static let displayInsetFraction: CGFloat = 0.12
    private nonisolated static let maxCornerRadius: CGFloat = 5
    private nonisolated static let cornerRadiusFraction: CGFloat = 0.1
    /// Same diagonal-hatch geometry as the cushion rasterizer, so cloud-only
    /// cells read identically in both styles.
    private nonisolated static let hatchStripePeriod = 4
    private nonisolated static let hatchContrast: Float = 0.14

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
                scale: scale,
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
                scale: scale,
                into: base,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow
            )
        }
    }
    #endif

    /// Serial cell pass, in scene order: parents precede their descendants,
    /// so nesting overdraw resolves correctly.
    private nonisolated static func renderCells(
        _ cells: [TreemapCell],
        origin: CGPoint,
        scale: CGFloat,
        into base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
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
    }

    private nonisolated static func pack(_ rgb: SIMD3<Float>) -> UInt32 {
        let r = UInt32(min(255, max(0, rgb.x * 255)))
        let g = UInt32(min(255, max(0, rgb.y * 255)))
        let b = UInt32(min(255, max(0, rgb.z * 255)))
        return r | (g << 8) | (b << 16) | (255 << 24)
    }

    /// Fills a horizontal pixel run with one RGBA word.
    private nonisolated static func fillRun(
        _ base: UnsafeMutablePointer<UInt8>,
        byteOffset: Int,
        pixelCount: Int,
        word: UInt32
    ) {
        guard pixelCount > 0 else { return }
        #if canImport(Darwin)
        var pattern = word
        memset_pattern4(base + byteOffset, &pattern, pixelCount * 4)
        #else
        let raw = UnsafeMutableRawPointer(base + byteOffset)
        for index in 0..<pixelCount {
            raw.storeBytes(of: word, toByteOffset: index * 4, as: UInt32.self)
        }
        #endif
    }

    /// Lerp between two packed RGBA words — the anti-aliasing mix for corner
    /// pixels straddling the border band's inner edge, where a hard cut
    /// leaves a visible staircase inside the rounded corner.
    private nonisolated static func mixWords(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let fraction = Float(t)
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Float((a >> shift) & 0xFF)
            let to = Float((b >> shift) & 0xFF)
            return UInt32((from + (to - from) * fraction).rounded()) << shift
        }
        return channel(0) | channel(8) | channel(16) | (255 << 24)
    }

    /// Blends `word` over the pixel already in the buffer by `coverage` —
    /// the anti-aliasing write for partially covered corner pixels. The
    /// buffer is premultiplied, so the same lerp covers the alpha channel:
    /// over a transparent background a corner pixel stays partially
    /// transparent instead of fringing dark.
    private nonisolated static func blendPixel(
        _ base: UnsafeMutablePointer<UInt8>,
        byteOffset: Int,
        word: UInt32,
        coverage: Double
    ) {
        let c = Float(coverage)
        let keep = 1 - c
        base[byteOffset] = UInt8(Float(base[byteOffset]) * keep + Float(word & 0xFF) * c)
        base[byteOffset + 1] = UInt8(Float(base[byteOffset + 1]) * keep + Float((word >> 8) & 0xFF) * c)
        base[byteOffset + 2] = UInt8(Float(base[byteOffset + 2]) * keep + Float((word >> 16) & 0xFF) * c)
        base[byteOffset + 3] = UInt8(Float(base[byteOffset + 3]) * keep + 255 * c)
    }

    private nonisolated static func rasterize(
        cell: TreemapCell,
        origin: CGPoint,
        scale: CGFloat,
        into base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        // Display rect: inset per side for the sibling gap, scaled with the
        // tile. Pixel rounding as in the cushion rasterizer.
        let inset = min(
            maxDisplayInset,
            min(cell.rect.width, cell.rect.height) * displayInsetFraction
        )
        let rect = cell.rect.insetBy(dx: inset, dy: inset)
        let scaleD = Double(scale)
        let originX = Double(origin.x)
        let originY = Double(origin.y)
        let x0 = max(0, Int(((Double(rect.minX) - originX) * scaleD).rounded()))
        let x1 = min(width, Int(((Double(rect.maxX) - originX) * scaleD).rounded()))
        let y0 = max(0, Int(((Double(rect.minY) - originY) * scaleD).rounded()))
        let y1 = min(height, Int(((Double(rect.maxY) - originY) * scaleD).rounded()))
        guard x1 > x0, y1 > y0 else { return }

        let fillWord = pack(cell.rgb)
        let borderWord = pack(cell.rgb * borderShade)
        // Hatch bands modulate the fill symmetrically about its own
        // brightness, mirroring the cushion hatch's contrast.
        let hatchBrightWord = pack(cell.rgb * (1 + hatchContrast))
        let hatchDarkWord = pack(cell.rgb * (1 - hatchContrast))
        let hatch = cell.isDataless

        // Border thickness in device pixels, clipped so tiny cells stay
        // visible as pure border rather than vanishing.
        var border = max(1, Int((borderWidth * scale).rounded()))
        border = min(border, (x1 - x0) / 2, (y1 - y0) / 2)
        let radius = min(
            Int((maxCornerRadius * scale).rounded()),
            Int((Double(min(x1 - x0, y1 - y0)) * cornerRadiusFraction).rounded(.down))
        )
        let radiusD = Double(radius)
        // Interior of the border band, measured as distance from the corner
        // center: outside `radiusD` is out of the tile, the band down to
        // `bandInner` is border, closer in is fill.
        let bandInner = Double(radius - border)

        // The interior word at a pixel: plain fill, or the hatch stripe the
        // pixel's diagonal lands on.
        func interiorWord(_ px: Int, _ py: Int) -> UInt32 {
            guard hatch else { return fillWord }
            return ((px + py) / hatchStripePeriod) & 1 == 0 ? hatchBrightWord : hatchDarkWord
        }

        // Border writes, feathered by ring (distance from the drawn rect's
        // edge): ring 0 blends over what's beneath, the ring touching the
        // interior mixes toward the fill, rings between stay solid.
        let innerBorderWord = mixWords(borderWord, fillWord, 0.5)
        func borderRun(row py: Int, from start: Int, to end: Int, ring: Int) {
            guard end > start else { return }
            let rowStart = py * bytesPerRow
            if ring == 0 {
                for px in start..<end {
                    blendPixel(
                        base, byteOffset: rowStart + px * 4,
                        word: borderWord, coverage: borderEdgeFeather
                    )
                }
            } else if ring == border - 1 {
                if hatch {
                    for px in start..<end {
                        fillRun(
                            base, byteOffset: rowStart + px * 4, pixelCount: 1,
                            word: mixWords(borderWord, interiorWord(px, py), 0.5)
                        )
                    }
                } else {
                    fillRun(
                        base, byteOffset: rowStart + start * 4,
                        pixelCount: end - start, word: innerBorderWord
                    )
                }
            } else {
                fillRun(
                    base, byteOffset: rowStart + start * 4,
                    pixelCount: end - start, word: borderWord
                )
            }
        }

        // A row that is border across its span: columns closer to a
        // vertical edge than the row is to its horizontal edge take that
        // column's (outer) ring instead.
        func borderRow(row py: Int, from start: Int, to end: Int, rowRing: Int) {
            guard end > start else { return }
            let midStart = min(max(start, x0 + rowRing), end)
            let midEnd = max(min(end, x1 - rowRing), midStart)
            for px in start..<midStart {
                borderRun(row: py, from: px, to: px + 1, ring: px - x0)
            }
            borderRun(row: py, from: midStart, to: midEnd, ring: rowRing)
            for px in midEnd..<end {
                borderRun(row: py, from: px, to: px + 1, ring: x1 - 1 - px)
            }
        }

        // Interior span fill for one row (hatch-aware).
        func fillInterior(row py: Int, from start: Int, to end: Int) {
            guard end > start else { return }
            let rowStart = py * bytesPerRow
            if !hatch {
                fillRun(base, byteOffset: rowStart + start * 4, pixelCount: end - start, word: fillWord)
                return
            }
            var px = start
            while px < end {
                let stripe = (px + py) / hatchStripePeriod
                let runEnd = min(end, (stripe + 1) * hatchStripePeriod - py)
                let word = stripe & 1 == 0 ? hatchBrightWord : hatchDarkWord
                fillRun(base, byteOffset: rowStart + px * 4, pixelCount: runEnd - px, word: word)
                px = runEnd
            }
        }

        for py in y0..<y1 {
            let rowStart = py * bytesPerRow
            let edgeDistY = min(py - y0, y1 - 1 - py)

            if edgeDistY >= radius {
                // No corner on this row: straight border rows/columns.
                if edgeDistY < border {
                    borderRow(row: py, from: x0, to: x1, rowRing: edgeDistY)
                    continue
                }
                for ring in 0..<border {
                    borderRun(row: py, from: x0 + ring, to: x0 + ring + 1, ring: ring)
                    borderRun(row: py, from: x1 - 1 - ring, to: x1 - ring, ring: ring)
                }
                fillInterior(row: py, from: x0 + border, to: x1 - border)
                continue
            }

            // Corner row. The two corner zones get per-pixel coverage
            // against the rounded outline (anti-aliased against whatever
            // lies beneath); the span between them is straight.
            let pyCenter = Double(py) + 0.5
            let cornerY = edgeDistY == py - y0 ? Double(y0 + radius) : Double(y1 - radius)
            let dy = pyCenter - cornerY

            func writeCornerPixel(_ px: Int, dx: Double) {
                let distance = (dx * dx + dy * dy).squareRoot()
                let coverage = min(max(radiusD + 0.5 - distance, 0), 1)
                guard coverage > 0 else { return }
                // Border→fill transition anti-aliases like the outline: a
                // pixel straddling the band's inner arc mixes the two words
                // by its interior fraction instead of hard-cutting. The
                // band's outermost ring feathers over what's beneath, like
                // the straight edges. The mix window spans the band's whole
                // innermost pixel ring — the straight edges mix that entire
                // ring toward the fill, and a narrower window leaves a
                // solid-dark arc sliver only the corners have.
                let word: UInt32
                let interiorFraction = bandInner <= 0
                    ? 0
                    : min(max(bandInner + 1 - distance, 0), 1)
                if interiorFraction <= 0 {
                    word = borderWord
                } else if interiorFraction >= 1 {
                    word = interiorWord(px, py)
                } else {
                    word = mixWords(borderWord, interiorWord(px, py), interiorFraction)
                }
                var effectiveCoverage = coverage
                if interiorFraction < 1, distance > radiusD - 1 {
                    effectiveCoverage *= borderEdgeFeather
                }
                if effectiveCoverage >= 1 {
                    fillRun(base, byteOffset: rowStart + px * 4, pixelCount: 1, word: word)
                } else {
                    blendPixel(base, byteOffset: rowStart + px * 4, word: word, coverage: effectiveCoverage)
                }
            }

            // The radius never exceeds a tenth of the short side, so the two
            // zones cannot overlap; the min is a pure safety clamp.
            let zoneWidth = min(radius, (x1 - x0) / 2)
            for px in x0..<(x0 + zoneWidth) {
                writeCornerPixel(px, dx: Double(x0 + radius) - (Double(px) + 0.5))
            }
            for px in (x1 - zoneWidth)..<x1 {
                writeCornerPixel(px, dx: (Double(px) + 0.5) - Double(x1 - radius))
            }

            // Straight middle of a corner row: top/bottom border rows keep
            // the border color; deeper rows are interior (the side borders
            // curved away into the corner zones).
            let mid0 = x0 + zoneWidth
            let mid1 = x1 - zoneWidth
            guard mid1 > mid0 else { continue }
            if edgeDistY < border {
                borderRow(row: py, from: mid0, to: mid1, rowRing: edgeDistY)
            } else {
                fillInterior(row: py, from: mid0, to: mid1)
            }
        }
    }
}
