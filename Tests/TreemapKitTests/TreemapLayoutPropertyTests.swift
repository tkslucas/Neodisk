//
//  TreemapLayoutPropertyTests.swift
//  TreemapKit
//
//  Randomized (but seeded, fully deterministic) property tests for the
//  squarified layout: area conservation, containment, non-overlap, and
//  input-order preservation.
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import TreemapKit

/// Deterministic PRNG (SplitMix64) so every run sees the same inputs.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct TreemapLayoutPropertyTests {
    @Test(arguments: Array(UInt64(0)..<24)) func randomizedLayoutHoldsInvariants(seed: UInt64) {
        var rng = SplitMix64(seed: 0xD15C &+ seed &* 0x1000_0000_01B3)
        let count = Int.random(in: 1...80, using: &rng)
        // Mix scales so some cases are heavily skewed (power-law-ish sizes).
        let weights = (0..<count).map { _ in
            Double.random(in: 0.001...1, using: &rng) * pow(10, Double.random(in: 0...4, using: &rng))
        }
        let rect = CGRect(
            x: Double.random(in: -500...500, using: &rng),
            y: Double.random(in: -500...500, using: &rng),
            width: Double.random(in: 1...2000, using: &rng),
            height: Double.random(in: 1...2000, using: &rng)
        )

        let rects = TreemapLayout.squarify(weights: weights, in: rect)
        #expect(rects.count == weights.count)

        let rectArea = Double(rect.width * rect.height)
        let tolerance = rectArea * 1e-6

        // Child areas sum to the parent rect's area.
        let totalArea = rects.reduce(0) { $0 + Double($1.width * $1.height) }
        #expect(abs(totalArea - rectArea) < tolerance, "seed \(seed): areas sum to \(totalArea), parent is \(rectArea)")

        // Every rect stays inside the parent.
        for (index, cell) in rects.enumerated() {
            #expect(cell.minX >= rect.minX - 1e-9, "seed \(seed): cell \(index) leaks left")
            #expect(cell.minY >= rect.minY - 1e-9, "seed \(seed): cell \(index) leaks up")
            #expect(cell.maxX <= rect.maxX + tolerance, "seed \(seed): cell \(index) leaks right")
            #expect(cell.maxY <= rect.maxY + tolerance, "seed \(seed): cell \(index) leaks down")
        }

        // No two rects overlap (shared edges are fine).
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                let overlapArea = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                #expect(overlapArea < tolerance, "seed \(seed): cells \(i) and \(j) overlap by \(overlapArea)")
            }
        }

        // Output order matches input order: the i-th rect carries the i-th
        // weight's share of the parent area.
        let totalWeight = weights.reduce(0, +)
        for (index, weight) in weights.enumerated() {
            let expected = rectArea * weight / totalWeight
            let actual = Double(rects[index].width * rects[index].height)
            #expect(
                abs(actual - expected) < tolerance,
                "seed \(seed): cell \(index) has area \(actual), weight demands \(expected)"
            )
        }
    }

    @Test(arguments: Array(UInt64(0)..<8)) func zeroWeightsGetEmptyRectsInOrder(seed: UInt64) {
        var rng = SplitMix64(seed: 0x2E80 &+ seed &* 0x9E37_79B9)
        let count = Int.random(in: 2...40, using: &rng)
        // Roughly a third of the entries are zero.
        let weights = (0..<count).map { _ in
            Bool.random(using: &rng) && Bool.random(using: &rng)
                ? 0 : Double.random(in: 0.5...100, using: &rng)
        }
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)

        let rects = TreemapLayout.squarify(weights: weights, in: rect)
        #expect(rects.count == weights.count)

        let rectArea = Double(rect.width * rect.height)
        let totalWeight = weights.reduce(0, +)
        let tolerance = rectArea * 1e-6

        for (index, weight) in weights.enumerated() {
            let actual = Double(rects[index].width * rects[index].height)
            if weight == 0 {
                #expect(actual == 0, "seed \(seed): zero weight \(index) got area \(actual)")
            } else if totalWeight > 0 {
                let expected = rectArea * weight / totalWeight
                #expect(
                    abs(actual - expected) < tolerance,
                    "seed \(seed): cell \(index) has area \(actual), weight demands \(expected)"
                )
            }
        }
    }
}
