//
//  CushionRenderGoldenTests.swift
//  TreemapKit
//
//  Golden-image regression test for the cushion render pipeline: a fixed
//  synthetic tree goes through TreemapLayout + CushionTreemapRenderer and the
//  result is compared per-pixel (small tolerance for float jitter) against a
//  checked-in PNG (Fixtures/cushion-golden.png). On failure the actual output
//  lands in the temporary directory for inspection.
//
//  To regenerate the golden after an intentional visual change: delete the
//  fixture, run this test once, and copy the dumped PNG from the path in the
//  failure message back to Tests/TreemapKitTests/Fixtures/cushion-golden.png.
//

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import TreemapKit
import UniformTypeIdentifiers

@Suite struct CushionRenderGoldenTests {
    /// Per-channel tolerance: absorbs benign float jitter (e.g. from future
    /// reassociation of shading math) without letting real regressions pass.
    private static let channelTolerance = 2

    @Test func rendererMatchesGoldenImage() throws {
        let image = try #require(Self.renderFixedScene(), "render produced no image")
        let actualPNG = try #require(Self.encodePNG(image), "PNG encode failed")
        // Golden and actual both go through the same PNG encode + decode
        // path, so any color-management the codec applies cancels out.
        let actual = try #require(Self.decodePNG(actualPNG), "PNG decode failed")

        guard let goldenURL = Bundle.module.url(
            forResource: "cushion-golden", withExtension: "png", subdirectory: "Fixtures"
        ) else {
            let dumped = Self.dump(actualPNG)
            Issue.record("golden fixture missing; actual render written to \(dumped.path())")
            return
        }
        let golden = try #require(
            Self.decodePNG(try Data(contentsOf: goldenURL)), "golden decode failed"
        )

        guard actual.width == golden.width, actual.height == golden.height else {
            let dumped = Self.dump(actualPNG)
            let message = "size mismatch: actual \(actual.width)x\(actual.height), golden "
                + "\(golden.width)x\(golden.height); actual written to \(dumped.path())"
            Issue.record(Comment(rawValue: message))
            return
        }

        var maxDelta = 0
        var differingBytes = 0
        for index in actual.pixels.indices {
            let delta = abs(Int(actual.pixels[index]) - Int(golden.pixels[index]))
            if delta > 0 { differingBytes += 1 }
            maxDelta = max(maxDelta, delta)
        }

        if maxDelta > Self.channelTolerance {
            let dumped = Self.dump(actualPNG)
            let message = "render deviates from golden: max channel delta \(maxDelta) "
                + "(tolerance \(Self.channelTolerance)), \(differingBytes) differing bytes; "
                + "actual written to \(dumped.path())"
            Issue.record(Comment(rawValue: message))
        }
    }

    // MARK: - Fixed scene

    /// A small deterministic treemap: fixed weights laid out by squarify, a
    /// shared root cushion ridge plus one ridge per cell, fixed palette.
    private static func renderFixedScene() -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let weights: [Double] = [34, 21, 13, 8, 8, 5, 3, 2, 1, 1, 0.5, 0.25]
        let palette: [SIMD3<Float>] = [
            SIMD3(0.32, 0.51, 0.78), SIMD3(0.76, 0.42, 0.30), SIMD3(0.38, 0.66, 0.42),
            SIMD3(0.72, 0.64, 0.28), SIMD3(0.56, 0.40, 0.70), SIMD3(0.30, 0.62, 0.64)
        ]

        var rootSurface = CushionSurface()
        rootSurface.addRidge(over: bounds, height: 0.5)

        let rects = TreemapLayout.squarify(weights: weights, in: bounds)
        let cells = rects.enumerated().map { index, rect in
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

        return CushionTreemapRenderer.render(cells: cells, bounds: bounds, scale: 2)
    }

    // MARK: - PNG helpers

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func decodePNG(_ data: Data) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, pixels)
    }

    private static func dump(_ png: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cushion-golden-actual-\(UUID().uuidString).png")
        try? png.write(to: url)
        return url
    }
}

#endif
