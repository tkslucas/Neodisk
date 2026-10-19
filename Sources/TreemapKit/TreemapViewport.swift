// Layout is computed at `viewSize × scale` and `origin` is the visible window's top-left,
// so scene geometry lands directly in view coordinates.

#if canImport(CoreGraphics)
import CoreGraphics
#elseif canImport(Foundation)
import Foundation  // CG geometry types off Darwin
#endif

public struct TreemapViewport: Equatable, Sendable {
    public var scale: CGFloat
    public var origin: CGPoint

    public init(scale: CGFloat = 1, origin: CGPoint = .zero) {
        self.scale = scale
        self.origin = origin
    }

    public static let identity = TreemapViewport()
    public static let maxScale: CGFloat = 4096

    /// Zooms by `magnification` keeping the content under `anchor` (view
    /// coordinates) stationary, clamped so the canvas always fills the view.
    public func zoomed(by magnification: CGFloat, anchor: CGPoint, viewSize: CGSize) -> TreemapViewport {
        let newScale = min(max(scale * magnification, 1), Self.maxScale)
        let factor = newScale / scale
        let anchored = CGPoint(
            x: (origin.x + anchor.x) * factor - anchor.x,
            y: (origin.y + anchor.y) * factor - anchor.y
        )
        return TreemapViewport(scale: newScale, origin: anchored)
            .clamped(viewSize: viewSize)
    }

    public func panned(by translation: CGSize, viewSize: CGSize) -> TreemapViewport {
        TreemapViewport(
            scale: scale,
            origin: CGPoint(x: origin.x - translation.width, y: origin.y - translation.height)
        )
        .clamped(viewSize: viewSize)
    }

    public func clamped(viewSize: CGSize) -> TreemapViewport {
        TreemapViewport(
            scale: scale,
            origin: CGPoint(
                x: min(max(0, origin.x), max(0, viewSize.width * scale - viewSize.width)),
                y: min(max(0, origin.y), max(0, viewSize.height * scale - viewSize.height))
            )
        )
    }

    /// The canvas-space window this viewport shows.
    public func visibleCanvasRect(viewSize: CGSize) -> CGRect {
        CGRect(origin: origin, size: viewSize)
    }

    #if canImport(CoreGraphics)
    /// p' = p·f + (o_r·f − o), with f the scale ratio, so a stale render tracks the live viewport until the
    /// next one. CoreGraphics-only; off-Darwin consumers do their own display mapping.
    public func displayTransform(fromRendered rendered: TreemapViewport) -> CGAffineTransform {
        let factor = scale / rendered.scale
        return CGAffineTransform(scaleX: factor, y: factor)
            .concatenating(CGAffineTransform(
                translationX: rendered.origin.x * factor - origin.x,
                y: rendered.origin.y * factor - origin.y
            ))
    }
    #endif
}
