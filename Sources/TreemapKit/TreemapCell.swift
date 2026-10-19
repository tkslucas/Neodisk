// The renderable unit of a cushion treemap (van Wijk and van de Wetering, "Cushion Treemaps", 1999).

#if canImport(CoreGraphics)
import CoreGraphics
#elseif canImport(Foundation)
import Foundation  // CG geometry types off Darwin
#endif

/// Only the gradient matters for shading, and it is linear per axis: dz/dx = xa + xb·x, dz/dy = ya + yb·y.
public struct CushionSurface: Sendable {
    public var xa: Double = 0
    public var xb: Double = 0
    public var ya: Double = 0
    public var yb: Double = 0

    public init() {}

    /// Adds one parabolic ridge of height `h` spanning `rect` on both axes.
    public nonisolated mutating func addRidge(over rect: CGRect, height h: Double) {
        let w = Double(rect.width)
        let hgt = Double(rect.height)
        guard w > 0, hgt > 0 else { return }
        xa += 4 * h * (Double(rect.minX) + Double(rect.maxX)) / w
        xb -= 8 * h / w
        ya += 4 * h * (Double(rect.minY) + Double(rect.maxY)) / hgt
        yb -= 8 * h / hgt
    }
}

public struct TreemapCell: Sendable {
    public let nodeID: String
    public let rect: CGRect
    public let rgb: SIMD3<Float>
    /// Excludes highlight dimming, cloud treatment and flat compositing, unlike `rgb`.
    public let swatchRGB: SIMD3<Float>
    public let surface: CushionSurface
    public let isDirectory: Bool
    /// Flat style only. Hit-testing prefers the deepest cell, so a container wins only on its visible frame;
    /// keyboard tile navigation skips containers.
    public var isContainer: Bool
    /// Set when this cell stands in for several small siblings that would
    /// each be too tiny to render individually. `nodeID` is their parent.
    public var aggregate: AggregateInfo?
    /// Set when this cell is the synthetic free-space block for the volume
    /// root; `nodeID` is then a synthetic ID that exists in no tree store.
    public var isFreeSpace: Bool
    /// `nodeID` is then a synthetic ID that exists in no tree store.
    public var isHiddenSpace: Bool
    /// The rasterizer hatches it so "not on disk" reads independent of hue, surviving the colorblind palette.
    public var isDataless: Bool

    public struct AggregateInfo: Equatable, Sendable {
        public let itemCount: Int
        public let totalSize: Int64

        public init(itemCount: Int, totalSize: Int64) {
            self.itemCount = itemCount
            self.totalSize = totalSize
        }
    }

    public init(
        nodeID: String,
        rect: CGRect,
        rgb: SIMD3<Float>,
        swatchRGB: SIMD3<Float>? = nil,
        surface: CushionSurface,
        isDirectory: Bool,
        isContainer: Bool = false,
        aggregate: AggregateInfo? = nil,
        isFreeSpace: Bool = false,
        isHiddenSpace: Bool = false,
        isDataless: Bool = false
    ) {
        self.nodeID = nodeID
        self.rect = rect
        self.rgb = rgb
        self.swatchRGB = swatchRGB ?? rgb
        self.surface = surface
        self.isDirectory = isDirectory
        self.isContainer = isContainer
        self.aggregate = aggregate
        self.isFreeSpace = isFreeSpace
        self.isHiddenSpace = isHiddenSpace
        self.isDataless = isDataless
    }
}
