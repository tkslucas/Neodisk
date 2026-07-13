//
//  TreemapCell.swift
//  TreemapKit
//
//  The renderable unit of a cushion treemap: a rect, its accumulated cushion
//  surface coefficients (van Wijk & van de Wetering, "Cushion Treemaps",
//  1999), and a base color. Knows nothing about what the cells represent.
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Accumulated cushion surface for a cell. The surface height field is a sum
/// of parabolas; only its gradient matters for shading, and the gradient is
/// linear per axis: dz/dx = xa + xb·x, dz/dy = ya + yb·y.
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
    public let surface: CushionSurface
    public let isDirectory: Bool
    /// Set when this cell stands in for several small siblings that would
    /// each be too tiny to render individually. `nodeID` is their parent.
    public var aggregate: AggregateInfo?
    /// Set when this cell is the synthetic free-space block for the volume
    /// root; `nodeID` is then a synthetic ID that exists in no tree store.
    public var isFreeSpace: Bool
    /// Set when this cell is the synthetic hidden-space block for the volume
    /// root (capacity the scan could not account for: purgeable space, local
    /// snapshots, unreadable files); `nodeID` is then a synthetic ID that
    /// exists in no tree store.
    public var isHiddenSpace: Bool
    /// Set when this cell's weight is cloud-only (a dataless file, or a
    /// directory whose bytes all live in the cloud): the rasterizer bakes a
    /// diagonal hatch over it so the space reads as "not on disk" independent
    /// of hue (and so it survives the colorblind palette).
    public var isDataless: Bool

    public struct AggregateInfo: Sendable {
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
        surface: CushionSurface,
        isDirectory: Bool,
        aggregate: AggregateInfo? = nil,
        isFreeSpace: Bool = false,
        isHiddenSpace: Bool = false,
        isDataless: Bool = false
    ) {
        self.nodeID = nodeID
        self.rect = rect
        self.rgb = rgb
        self.surface = surface
        self.isDirectory = isDirectory
        self.aggregate = aggregate
        self.isFreeSpace = isFreeSpace
        self.isHiddenSpace = isHiddenSpace
        self.isDataless = isDataless
    }
}
