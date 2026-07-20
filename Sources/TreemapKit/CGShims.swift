//
//  CGShims.swift
//  TreemapKit
//
//  Minimal CoreGraphics geometry stand-ins for platforms without
//  CoreGraphics (the WebAssembly demo build). Darwin builds use the real
//  types; this file compiles to nothing there. Only the API TreemapKit and
//  its off-platform consumers actually touch is provided.
//

#if !canImport(CoreGraphics)

public typealias CGFloat = Double

public struct CGPoint: Equatable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public static let zero = CGPoint(x: 0, y: 0)

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

public struct CGSize: Equatable, Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public static let zero = CGSize(width: 0, height: 0)

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
}

public struct CGRect: Equatable, Hashable, Sendable {
    public var origin: CGPoint
    public var size: CGSize

    public static let zero = CGRect(origin: .zero, size: .zero)

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(
            origin: CGPoint(x: x, y: y),
            size: CGSize(width: width, height: height)
        )
    }

    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    public func contains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + dx,
            y: origin.y + dy,
            width: size.width - 2 * dx,
            height: size.height - 2 * dy
        )
    }
}

#endif
