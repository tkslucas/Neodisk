//
//  TreemapResizePolicy.swift
//  Neodisk
//
//  Presentation math used while a pane resize temporarily stretches the last
//  crisp treemap scene. Exact layout/raster work happens after resizing
//  settles; this transform keeps the existing pixels filling the live view.
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import TreemapKit

package enum TreemapResizePolicy {
    /// Quiet period before an exact scene is built for the latest pane size.
    package static let settleDelay: Duration = .milliseconds(100)

    /// Maps rendered-scene coordinates into the live view while its size or
    /// viewport differs. Canvas positions are normalized by each view size,
    /// so a resize fills the pane and the existing viewport-only transform is
    /// unchanged when both sizes match.
    package static func displayMapping(
        liveViewport: TreemapViewport,
        liveSize: CGSize,
        renderedViewport: TreemapViewport,
        renderedSize: CGSize
    ) -> TreemapDisplayMapping {
        guard liveSize.width > 0, liveSize.height > 0,
              renderedSize.width > 0, renderedSize.height > 0,
              renderedViewport.scale > 0 else {
            return .identity
        }

        let scaleX = liveSize.width * liveViewport.scale
            / (renderedSize.width * renderedViewport.scale)
        let scaleY = liveSize.height * liveViewport.scale
            / (renderedSize.height * renderedViewport.scale)

        return TreemapDisplayMapping(
            scaleX: scaleX,
            scaleY: scaleY,
            translationX: renderedViewport.origin.x * scaleX - liveViewport.origin.x,
            translationY: renderedViewport.origin.y * scaleY - liveViewport.origin.y
        )
    }

    #if canImport(CoreGraphics)
    /// `displayMapping` as the layer transform the macOS treemap applies.
    package static func displayTransform(
        liveViewport: TreemapViewport,
        liveSize: CGSize,
        renderedViewport: TreemapViewport,
        renderedSize: CGSize
    ) -> CGAffineTransform {
        let mapping = displayMapping(
            liveViewport: liveViewport,
            liveSize: liveSize,
            renderedViewport: renderedViewport,
            renderedSize: renderedSize
        )
        return CGAffineTransform(scaleX: mapping.scaleX, y: mapping.scaleY)
            .concatenating(CGAffineTransform(translationX: mapping.translationX, y: mapping.translationY))
    }
    #endif
}

/// A scale-then-translate map from rendered-scene coordinates to live view
/// coordinates — what a shell applies to the last crisp render while a
/// resize or zoom gesture outruns re-rendering.
package struct TreemapDisplayMapping: Equatable, Sendable {
    package var scaleX: CGFloat
    package var scaleY: CGFloat
    package var translationX: CGFloat
    package var translationY: CGFloat

    package static let identity = TreemapDisplayMapping(scaleX: 1, scaleY: 1, translationX: 0, translationY: 0)

    package init(scaleX: CGFloat, scaleY: CGFloat, translationX: CGFloat, translationY: CGFloat) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.translationX = translationX
        self.translationY = translationY
    }

    package func apply(to point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scaleX + translationX, y: point.y * scaleY + translationY)
    }
}
