//
//  TreemapResizePolicy.swift
//  Neodisk
//
//  Presentation math used while a pane resize temporarily stretches the last
//  crisp treemap scene. Exact layout/raster work happens after resizing
//  settles; this transform keeps the existing pixels filling the live view.
//

import CoreGraphics
import TreemapKit

enum TreemapResizePolicy {
    /// Quiet period before an exact scene is built for the latest pane size.
    static let settleDelay: Duration = .milliseconds(100)

    /// Maps rendered-scene coordinates into the live view while its size or
    /// viewport differs. Canvas positions are normalized by each view size,
    /// so a resize fills the pane and the existing viewport-only transform is
    /// unchanged when both sizes match.
    static func displayTransform(
        liveViewport: TreemapViewport,
        liveSize: CGSize,
        renderedViewport: TreemapViewport,
        renderedSize: CGSize
    ) -> CGAffineTransform {
        guard liveSize.width > 0, liveSize.height > 0,
              renderedSize.width > 0, renderedSize.height > 0,
              renderedViewport.scale > 0 else {
            return .identity
        }

        let scaleX = liveSize.width * liveViewport.scale
            / (renderedSize.width * renderedViewport.scale)
        let scaleY = liveSize.height * liveViewport.scale
            / (renderedSize.height * renderedViewport.scale)

        return CGAffineTransform(scaleX: scaleX, y: scaleY)
            .concatenating(CGAffineTransform(
                translationX: renderedViewport.origin.x * scaleX - liveViewport.origin.x,
                y: renderedViewport.origin.y * scaleY - liveViewport.origin.y
            ))
    }
}
