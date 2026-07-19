//
//  FlatRendererTests.swift
//  TreemapKit
//
//  Pixel probes for the flat renderer: interior fill, darkened border,
//  overdraw order (containers under children), dataless hatch bands, and
//  rasterizeRGBA/render parity (the same contract the cushion path pins).
//

import CoreGraphics
import Foundation
import Testing
import TreemapKit

@Suite struct FlatRendererTests {
    private func pixel(
        _ raster: (pixels: [UInt8], width: Int, height: Int),
        x: Int,
        y: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = (y * raster.width + x) * 4
        return (
            raster.pixels[offset], raster.pixels[offset + 1],
            raster.pixels[offset + 2], raster.pixels[offset + 3]
        )
    }

    private func cell(
        _ id: String,
        _ rect: CGRect,
        rgb: SIMD3<Float>,
        isContainer: Bool = false,
        isDataless: Bool = false
    ) -> TreemapCell {
        TreemapCell(
            nodeID: id, rect: rect, rgb: rgb, surface: CushionSurface(),
            isDirectory: isContainer, isContainer: isContainer, isDataless: isDataless
        )
    }

    @Test func fillAndBorderPixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cells = [cell("a", bounds, rgb: SIMD3(1, 0, 0))]
        let raster = try #require(
            FlatTreemapRenderer.rasterizeRGBA(cells: cells, bounds: bounds, scale: 1)
        )

        let interior = pixel(raster, x: 50, y: 50)
        #expect(interior.r == 255 && interior.g == 0 && interior.b == 0 && interior.a == 255)

        // The display inset leaves a gap: the rect's own edge row shows the
        // background, the first drawn row is the darkened border.
        let gap = pixel(raster, x: 50, y: 0)
        #expect(gap.r == 18 && gap.g == 18 && gap.b == 22)
        // Border shade: the darkened fill, feathered over the background
        // on its outermost ring (so a whisper of the backdrop's green/blue
        // channels survives the blend).
        let edge = pixel(raster, x: 50, y: 1)
        #expect(edge.r < 200 && edge.r > 100)
        #expect(edge.g < 10 && edge.b < 10)

        // Rounded corner: the cut reveals the background inside the drawn
        // rect's corner.
        let corner = pixel(raster, x: 1, y: 1)
        #expect(corner.r == 18 && corner.g == 18 && corner.b == 22)
    }

    @Test func smallTilesStayNearlySquare() throws {
        let bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        let cells = [cell("s", bounds, rgb: SIMD3(1, 0, 0))]
        let raster = try #require(
            FlatTreemapRenderer.rasterizeRGBA(cells: cells, bounds: bounds, scale: 1)
        )

        // The radius scales with the tile (~1px here), so this edge pixel two
        // rows below the corner is drawn — a constant 3pt radius would cut it
        // away and round the tile into a pill.
        let edge = pixel(raster, x: 1, y: 3)
        #expect(edge.r > 50, "small tile lost its edge to over-rounding")
    }

    @Test func laterCellsOverdrawEarlierOnes() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cells = [
            cell("parent", bounds, rgb: SIMD3(0, 0, 1), isContainer: true),
            cell("child", CGRect(x: 20, y: 30, width: 60, height: 60), rgb: SIMD3(0, 1, 0)),
        ]
        let raster = try #require(
            FlatTreemapRenderer.rasterizeRGBA(cells: cells, bounds: bounds, scale: 1)
        )

        // Child interior wins where they overlap...
        let inChild = pixel(raster, x: 50, y: 60)
        #expect(inChild.g == 255 && inChild.b == 0)
        // ...the container's header region stays its own fill.
        let inHeader = pixel(raster, x: 50, y: 10)
        #expect(inHeader.b == 255 && inHeader.g == 0)
    }

    @Test func datalessCellsGetHatchBands() throws {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let cells = [cell("a", bounds, rgb: SIMD3(0.5, 0.5, 0.5), isDataless: true)]
        let raster = try #require(
            FlatTreemapRenderer.rasterizeRGBA(cells: cells, bounds: bounds, scale: 1)
        )

        // Along a row the diagonal bands alternate: collect the distinct
        // red values away from the border and expect exactly two shades.
        var shades = Set<UInt8>()
        for x in 4..<60 {
            shades.insert(pixel(raster, x: x, y: 32).r)
        }
        #expect(shades.count == 2)
        let sorted = shades.sorted()
        #expect(sorted[1] - sorted[0] > 20)
    }

    @Test func rasterizeRGBAMatchesRenderPixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 90)
        let cells = [
            cell("parent", bounds, rgb: SIMD3(0.2, 0.4, 0.8), isContainer: true),
            cell("a", CGRect(x: 4, y: 20, width: 60, height: 66), rgb: SIMD3(0.9, 0.3, 0.1)),
            cell("b", CGRect(x: 64, y: 20, width: 52, height: 66), rgb: SIMD3(0.1, 0.8, 0.4), isDataless: true),
        ]

        let portable = try #require(
            FlatTreemapRenderer.rasterizeRGBA(cells: cells, bounds: bounds, scale: 2)
        )
        let image = try #require(
            FlatTreemapRenderer.render(cells: cells, bounds: bounds, scale: 2)
        )

        #expect(portable.width == image.width)
        #expect(portable.height == image.height)
        let cgPixels = try #require(image.dataProvider?.data as Data?)
        #expect(Array(cgPixels) == portable.pixels)
    }
}
