//
//  CushionRasterizeRGBATests.swift
//  TreemapKit
//
//  The portable `rasterizeRGBA` entry point must produce exactly the pixels the
//  CGImage `render` path draws: both fill the same background and run the same
//  per-cell rasterizer, so their buffers are byte-identical. This pins the
//  wasm-consumable path to the shipping renderer.
//

import CoreGraphics
import Foundation
import Testing
import TreemapKit

@Suite struct CushionRasterizeRGBATests {
    @Test func rasterizeRGBAMatchesRenderPixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        let cells = Self.fixedCells(in: bounds)

        let portable = try #require(
            CushionTreemapRenderer.rasterizeRGBA(cells: cells, bounds: bounds, scale: 2),
            "rasterizeRGBA produced no pixels"
        )
        let image = try #require(
            CushionTreemapRenderer.render(cells: cells, bounds: bounds, scale: 2),
            "render produced no image"
        )

        #expect(portable.width == image.width)
        #expect(portable.height == image.height)

        let cgPixels = try #require(
            image.dataProvider?.data as Data?, "CGImage has no backing data"
        )
        #expect(cgPixels.count == portable.pixels.count)
        #expect(Array(cgPixels) == portable.pixels)
    }

    @Test func rasterizeRGBAReturnsAlphaOpaqueRGBA() throws {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
        let result = try #require(
            CushionTreemapRenderer.rasterizeRGBA(
                cells: Self.fixedCells(in: bounds), bounds: bounds, scale: 1
            )
        )

        #expect(result.pixels.count == result.width * result.height * 4)
        // Straight RGBA, alpha always 255 — every 4th byte is opaque.
        #expect(stride(from: 3, to: result.pixels.count, by: 4).allSatisfy { result.pixels[$0] == 255 })
    }

    @Test func degenerateBoundsProduceNoPixels() {
        #expect(CushionTreemapRenderer.rasterizeRGBA(
            cells: [], bounds: CGRect(x: 0, y: 0, width: 0, height: 40), scale: 2
        ) == nil)
    }

    private static func fixedCells(in bounds: CGRect) -> [TreemapCell] {
        let weights: [Double] = [21, 13, 8, 5, 3, 2, 1, 1]
        let palette: [SIMD3<Float>] = [
            SIMD3(0.32, 0.51, 0.78), SIMD3(0.76, 0.42, 0.30),
            SIMD3(0.38, 0.66, 0.42), SIMD3(0.72, 0.64, 0.28)
        ]

        var rootSurface = CushionSurface()
        rootSurface.addRidge(over: bounds, height: 0.5)

        return TreemapLayout.squarify(weights: weights, in: bounds).enumerated().map { index, rect in
            var surface = rootSurface
            surface.addRidge(over: rect, height: 0.5)
            return TreemapCell(
                nodeID: "node-\(index)",
                rect: rect,
                rgb: palette[index % palette.count],
                surface: surface,
                isDirectory: false
            )
        }
    }
}
