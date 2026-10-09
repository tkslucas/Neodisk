//
//  TreemapLayoutTests.swift
//  TreemapKit
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import TreemapKit

@Suite struct TreemapLayoutTests {
    @Test func singleWeightFillsRect() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let rects = TreemapLayout.squarify(weights: [42], in: rect)
        #expect(rects == [rect])
    }

    @Test func emptyInputProducesNoRects() {
        #expect(TreemapLayout.squarify(weights: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }

    @Test func areasAreProportionalToWeights() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(weights: weights, in: rect)
        let totalWeight = weights.reduce(0, +)

        #expect(rects.count == weights.count)
        for (weight, cell) in zip(weights, rects) {
            let expectedArea = Double(rect.width * rect.height) * weight / totalWeight
            let actualArea = Double(cell.width * cell.height)
            #expect(abs(actualArea - expectedArea) < 0.001)
        }
    }

    @Test func cellsStayInsideBoundsAndDoNotOverlap() {
        let rect = CGRect(x: 5, y: 7, width: 320, height: 240)
        let weights = (1...40).map { Double($0 * $0) }
        let rects = TreemapLayout.squarify(weights: weights, in: rect)

        for cell in rects {
            #expect(cell.minX >= rect.minX - 0.001)
            #expect(cell.minY >= rect.minY - 0.001)
            #expect(cell.maxX <= rect.maxX + 0.001)
            #expect(cell.maxY <= rect.maxY + 0.001)
        }

        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                let overlapArea = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                #expect(overlapArea < 0.001, "cells \(i) and \(j) overlap")
            }
        }
    }

    @Test func zeroTotalWeightProducesEmptyRects() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let rects = TreemapLayout.squarify(weights: [0, 0], in: rect)
        #expect(rects.count == 2)
        #expect(rects.allSatisfy { $0.isEmpty })
    }

    @Test func zeroWeightAmongPositiveWeightsGetsEmptyRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rects = TreemapLayout.squarify(weights: [10, 0, 10], in: rect)
        #expect(rects.count == 3)
        #expect(rects[1].width * rects[1].height < 0.001)
        let coveredArea = Double(rects[0].width * rects[0].height + rects[2].width * rects[2].height)
        #expect(abs(coveredArea - 10_000) < 0.01)
    }

    @Test func aspectRatiosAreReasonable() {
        // Squarified layout should avoid extreme slivers for balanced weights.
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let weights = Array(repeating: 1.0, count: 12)
        let rects = TreemapLayout.squarify(weights: weights, in: rect)

        for cell in rects {
            let ratio = Double(max(cell.width, cell.height) / min(cell.width, cell.height))
            #expect(ratio < 3, "aspect ratio \(ratio) too extreme")
        }
    }
}

@Suite struct CushionSurfaceTests {
    @Test func ridgeGradientIsZeroAtCenterAndSymmetric() {
        var surface = CushionSurface()
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        surface.addRidge(over: rect, height: 0.5)

        let centerGradient = surface.xa + surface.xb * 5
        #expect(abs(centerGradient) < 1e-9)

        let leftGradient = surface.xa + surface.xb * 1
        let rightGradient = surface.xa + surface.xb * 9
        #expect(abs(leftGradient + rightGradient) < 1e-9)
        #expect(leftGradient > 0)
    }

    @Test func degenerateRectAddsNothing() {
        var surface = CushionSurface()
        surface.addRidge(over: CGRect(x: 0, y: 0, width: 0, height: 10), height: 0.5)
        #expect(surface.xa == 0 && surface.xb == 0 && surface.ya == 0 && surface.yb == 0)
    }
}
