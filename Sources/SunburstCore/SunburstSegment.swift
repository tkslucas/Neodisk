//
//  SunburstSegment.swift
//  SunburstCore
//
//  The laid-out unit of the sunburst: one arc's polar geometry, its tree node
//  (nil for aggregate/free/hidden arcs), and its color token. Angles are
//  radians clockwise from 12 o'clock; radii are fractions of the chart radius.
//  SwiftUI's Angle/CGFloat are deliberately absent — this is plain Double so
//  the layout is consumable off-platform.
//

public struct SunburstSegment: Identifiable, Hashable, Sendable {
    public let id: String
    /// The represented tree node; nil for aggregate and free-space segments.
    public let nodeID: String?
    public let label: String
    /// Radians clockwise from 12 o'clock.
    public let startAngle: Double
    public let endAngle: Double
    /// Fraction of the chart radius (`min(w, h) / 2`).
    public let innerRadius: Double
    public let outerRadius: Double
    public let depth: Int
    public let colorToken: SunburstColorToken
    /// Fill resolved by the `styled` pass (kind/age colors, branch hues,
    /// highlight dimming); nil for segments without a node, where the
    /// drawing styler derives a fallback from `colorToken`.
    public var fillRGB: SIMD3<Float>?
    public let totalSize: Int64
    public let isAggregate: Bool
    /// For aggregate segments: the folder whose small children pooled here,
    /// so hover can report "N smaller items in <folder>".
    public let parentFolderID: String?
    /// For aggregate segments: how many items pooled (descendant-counted,
    /// matching the treemap's aggregate cells).
    public let itemCount: Int

    public init(
        id: String,
        nodeID: String?,
        label: String,
        startAngle: Double,
        endAngle: Double,
        innerRadius: Double,
        outerRadius: Double,
        depth: Int,
        colorToken: SunburstColorToken,
        fillRGB: SIMD3<Float>? = nil,
        totalSize: Int64,
        isAggregate: Bool,
        parentFolderID: String? = nil,
        itemCount: Int = 0
    ) {
        self.id = id
        self.nodeID = nodeID
        self.label = label
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.depth = depth
        self.colorToken = colorToken
        self.fillRGB = fillRGB
        self.totalSize = totalSize
        self.isAggregate = isAggregate
        self.parentFolderID = parentFolderID
        self.itemCount = itemCount
    }

    public var isFreeSpace: Bool {
        colorToken.role == .freeSpace
    }

    public var isHiddenSpace: Bool {
        colorToken.role == .hiddenSpace
    }
}

/// The angular/seam math from the arc-path builder, pure so it can be shared
/// by NeodiskUI's SwiftUI `Path` construction and any off-platform renderer.
public enum SunburstArcGeometry {
    /// Draw-time angular edges: neighbors in a ring each give up half the
    /// seam so the background shows as a hairline between them. Full-circle
    /// arcs stay sealed (a lone slit at 12 o'clock reads as a glitch), and
    /// tiny slivers cap the inset so the seam yields before the item does.
    public nonisolated static func seamInsetAngles(
        startRadians: Double,
        endRadians: Double,
        innerRadius: Double,
        outerRadius: Double
    ) -> (start: Double, end: Double) {
        let span = endRadians - startRadians
        guard span > 0, span < (2 * .pi) - 0.001 else {
            return (startRadians, endRadians)
        }

        let midRadius = (innerRadius + outerRadius) / 2
        guard midRadius > 0.001 else {
            return (startRadians, endRadians)
        }

        let inset = min((SunburstLayout.angularSeam / 2) / midRadius, span * 0.18)
        return (startRadians + inset, endRadians - inset)
    }
}
