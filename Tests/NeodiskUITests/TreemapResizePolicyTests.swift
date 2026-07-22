import CoreGraphics
import Testing
import TreemapKit
@testable import NeodiskUI

struct TreemapResizePolicyTests {
    @Test func equalSizesMatchViewportTransform() {
        let rendered = TreemapViewport(scale: 2, origin: CGPoint(x: 120, y: 80))
        let live = TreemapViewport(scale: 3, origin: CGPoint(x: 250, y: 140))
        let size = CGSize(width: 900, height: 600)

        let expected = live.displayTransform(fromRendered: rendered)
        let actual = TreemapResizePolicy.displayTransform(
            liveViewport: live,
            liveSize: size,
            renderedViewport: rendered,
            renderedSize: size
        )

        #expect(actual == expected)
    }

    @Test func identityViewportStretchesRenderedSceneToLiveSize() {
        let transform = TreemapResizePolicy.displayTransform(
            liveViewport: .identity,
            liveSize: CGSize(width: 1_200, height: 500),
            renderedViewport: .identity,
            renderedSize: CGSize(width: 800, height: 400)
        )

        let renderedBounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        #expect(renderedBounds.applying(transform) == CGRect(x: 0, y: 0, width: 1_200, height: 500))
    }

    @Test func inverseTransformKeepsHitTestingAlignedDuringResize() {
        let renderedViewport = TreemapViewport(
            scale: 2, origin: CGPoint(x: 100, y: 60)
        )
        let liveViewport = TreemapViewport(
            scale: 2.5, origin: CGPoint(x: 210, y: 95)
        )
        let transform = TreemapResizePolicy.displayTransform(
            liveViewport: liveViewport,
            liveSize: CGSize(width: 1_100, height: 700),
            renderedViewport: renderedViewport,
            renderedSize: CGSize(width: 900, height: 600)
        )
        let scenePoint = CGPoint(x: 420, y: 260)
        let livePoint = scenePoint.applying(transform)

        let recovered = livePoint.applying(transform.inverted())
        #expect(abs(recovered.x - scenePoint.x) < 0.000_001)
        #expect(abs(recovered.y - scenePoint.y) < 0.000_001)
    }

    @Test func degenerateSizeFallsBackToIdentity() {
        #expect(TreemapResizePolicy.displayTransform(
            liveViewport: .identity,
            liveSize: .zero,
            renderedViewport: .identity,
            renderedSize: CGSize(width: 800, height: 600)
        ) == .identity)
    }
}
