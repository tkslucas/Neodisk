//
//  HatchRasterTests.swift
//  TreemapKit
//
//  The cloud-only hatch: a dataless cell must rasterize as a two-level
//  diagonal stripe pattern, symmetric about the plain fill, with the SIMD
//  body and the scalar tail agreeing pixel-for-pixel (no seam).
//

import CoreGraphics
import Testing
import TreemapKit

@Suite struct HatchRasterTests {
    /// Fills the whole bounds with one flat-surface cell so shading is uniform
    /// and any per-pixel variation comes purely from the hatch. Width and
    /// height are deliberately not multiples of the 8-wide SIMD stride, so the
    /// scalar tail runs alongside the vector body.
    private static let width = 13
    private static let height = 11
    private static let stripePeriod = 4

    private static func render(dataless: Bool) -> [UInt32] {
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let cell = TreemapCell(
            nodeID: "n", rect: bounds, rgb: SIMD3(0.5, 0.5, 0.5),
            surface: CushionSurface(), isDirectory: false, isDataless: dataless
        )
        let out = CushionTreemapRenderer.rasterizeRGBA(cells: [cell], bounds: bounds, scale: 1)!
        var words: [UInt32] = []
        var i = 0
        while i < out.pixels.count {
            let r = UInt32(out.pixels[i])
            let g = UInt32(out.pixels[i + 1]) << 8
            let b = UInt32(out.pixels[i + 2]) << 16
            words.append(r | g | b)
            i += 4
        }
        return words
    }

    private static func brightStripe(x: Int, y: Int) -> Bool {
        ((x + y) / stripePeriod) & 1 == 0
    }

    @Test func plainCellRendersFlat() {
        let words = Set(Self.render(dataless: false))
        #expect(words.count == 1)
    }

    @Test func datalessCellRendersTwoLevelDiagonalHatch() throws {
        let plain = try #require(Self.render(dataless: false).first)
        let hatched = Self.render(dataless: true)

        let distinct = Set(hatched)
        #expect(distinct.count == 2)

        // Split the two levels and confirm they straddle the plain fill: the
        // hatch nudges symmetrically about the cell's own brightness.
        let bright = try #require(hatched.first { $0 > plain })
        let dark = try #require(hatched.first { $0 < plain })
        #expect(bright > plain)
        #expect(dark < plain)

        // Every pixel must land on the level its (x + y) diagonal parity
        // predicts. A body/tail disagreement would misplace a pixel here.
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let word = hatched[y * Self.width + x]
                let expected = Self.brightStripe(x: x, y: y) ? bright : dark
                #expect(word == expected, "pixel (\(x), \(y))")
            }
        }
    }
}
