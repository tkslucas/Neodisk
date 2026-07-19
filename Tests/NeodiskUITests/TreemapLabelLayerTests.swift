//
//  TreemapLabelLayerTests.swift
//  Neodisk
//
//  Treemap label text layers: pre-ellipsizing long names to the label rect
//  (CATextLayer's own truncation draws nothing at all once a string
//  overflows, so a layer must never be handed one that needs truncating),
//  and a render check that an overflowing name still puts pixels on screen.
//

import AppKit
import CoreGraphics
import Testing
@testable import NeodiskUI

@Suite @MainActor struct TreemapLabelLayerTests {
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white,
    ]

    private func measured(_ string: String) -> CGFloat {
        NSAttributedString(string: string, attributes: Self.attributes).size().width
    }

    @Test func shortNameSurvivesUntouched() {
        let text = "other"
        #expect(TreemapNSView.endTruncated(
            text, attributes: Self.attributes, width: 148
        ) == text)
    }

    @Test func longNameEllipsizesAtTheEndKeepingTheHead() {
        let text = "DesigningYourLifeShowcase"
        let fitted = TreemapNSView.endTruncated(
            text, attributes: Self.attributes, width: 100
        )
        #expect(fitted.hasSuffix("…"))
        #expect(measured(fitted) <= 100)
        #expect(text.hasPrefix(fitted.dropLast()))
        // Not degenerate: a 100pt rect fits far more than the bare ellipsis.
        #expect(fitted.count > 5)
    }

    @Test func narrowestRectDegradesToBareEllipsis() {
        let fitted = TreemapNSView.endTruncated(
            "DesigningYourLifeShowcase", attributes: Self.attributes, width: 10
        )
        #expect(fitted == "…")
    }

    /// The regression that motivated all of this: a header label whose name
    /// overflows its strip must still render visible pixels. Guards against
    /// any future reintroduction of CATextLayer-side truncation.
    @Test func overflowingHeaderLabelRendersPixels() throws {
        let label = TreemapScene.CellLabel(
            id: "/scan/DesigningYourLifeShowcase",
            text: "DesigningYourLifeShowcase",
            rect: CGRect(x: 0, y: 0, width: 100, height: 15),
            isHeader: true
        )
        let layer = TreemapNSView.labelLayer(
            for: label, font: Self.font, textColor: .white,
            shadowOpacity: 0, backingScale: 2
        )
        let width = 200, height = 30
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var litPixels = 0
        for index in stride(from: 3, to: width * height * 4, by: 4)
        where data[index] > 0 { litPixels += 1 }
        #expect(litPixels > 50)
    }
}
