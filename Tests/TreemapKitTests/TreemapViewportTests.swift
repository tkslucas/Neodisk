//
//  TreemapViewportTests.swift
//  TreemapKit
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import TreemapKit

@Suite struct TreemapViewportTests {
    private let viewSize = CGSize(width: 800, height: 600)

    @Test func zoomKeepsAnchorStationary() {
        let anchor = CGPoint(x: 200, y: 150)
        let start = TreemapViewport(scale: 2, origin: CGPoint(x: 300, y: 200))
        let zoomed = start.zoomed(by: 1.5, anchor: anchor, viewSize: viewSize)

        // The canvas point under the anchor before must sit under it after.
        let canvasX = (start.origin.x + anchor.x) / start.scale
        let canvasY = (start.origin.y + anchor.y) / start.scale
        #expect(abs(canvasX * zoomed.scale - zoomed.origin.x - anchor.x) < 1e-9)
        #expect(abs(canvasY * zoomed.scale - zoomed.origin.y - anchor.y) < 1e-9)
    }

    @Test func zoomOutClampsAtIdentityScale() {
        let start = TreemapViewport(scale: 1.2, origin: CGPoint(x: 50, y: 40))
        let zoomed = start.zoomed(by: 0.1, anchor: CGPoint(x: 400, y: 300), viewSize: viewSize)
        #expect(zoomed.scale == 1)
        #expect(zoomed.origin == .zero)
    }

    @Test func panNeverExposesSpaceBeyondCanvas() {
        let start = TreemapViewport(scale: 2, origin: CGPoint(x: 100, y: 100))
        let pannedFarRight = start.panned(
            by: CGSize(width: -10_000, height: -10_000), viewSize: viewSize
        )
        #expect(pannedFarRight.origin.x == viewSize.width)
        #expect(pannedFarRight.origin.y == viewSize.height)

        let pannedFarLeft = start.panned(
            by: CGSize(width: 10_000, height: 10_000), viewSize: viewSize
        )
        #expect(pannedFarLeft.origin == .zero)
    }

    @Test func panAtIdentityScaleIsPinned() {
        let panned = TreemapViewport.identity.panned(
            by: CGSize(width: -50, height: 30), viewSize: viewSize
        )
        #expect(panned == .identity)
    }

    @Test func zoomWithZeroViewSizeDoesNotTrap() {
        let zoomed = TreemapViewport.identity.zoomed(
            by: 3, anchor: .zero, viewSize: .zero
        )
        #expect(zoomed.scale == 3)
        #expect(zoomed.origin == .zero)
    }

    #if canImport(CoreGraphics)
    @Test func displayTransformIsIdentityWhenRenderMatches() {
        let viewport = TreemapViewport(scale: 3, origin: CGPoint(x: 120, y: 80))
        #expect(viewport.displayTransform(fromRendered: viewport) == .identity)
    }

    @Test func displayTransformMapsCanvasPointsConsistently() {
        let rendered = TreemapViewport(scale: 2, origin: CGPoint(x: 100, y: 60))
        let live = TreemapViewport(scale: 3, origin: CGPoint(x: 500, y: 400))
        let transform = live.displayTransform(fromRendered: rendered)

        // Any canvas point projected through both viewports must be related
        // by the display transform.
        for canvasPoint in [CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.9, y: 0.1)] {
            let renderedPoint = CGPoint(
                x: canvasPoint.x * viewSize.width * rendered.scale - rendered.origin.x,
                y: canvasPoint.y * viewSize.height * rendered.scale - rendered.origin.y
            )
            let livePoint = CGPoint(
                x: canvasPoint.x * viewSize.width * live.scale - live.origin.x,
                y: canvasPoint.y * viewSize.height * live.scale - live.origin.y
            )
            let mapped = renderedPoint.applying(transform)
            #expect(abs(mapped.x - livePoint.x) < 1e-6)
            #expect(abs(mapped.y - livePoint.y) < 1e-6)
        }
    }
    #endif
}
