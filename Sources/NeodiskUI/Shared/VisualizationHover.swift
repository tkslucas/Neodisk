//
//  VisualizationHover.swift
//  Neodisk
//
//  One atomic hover identity shared by the treemap, sunburst, tooltip, and
//  status bar. Keeping the semantic swatch with the identity makes hover
//  publication O(1) and prevents partially updated hover combinations.
//

import Foundation

enum VisualizationHover: Equatable, Sendable {
    case node(id: String, swatchRGB: SIMD3<Float>)
    case aggregate(folderID: String, itemCount: Int, totalSize: Int64, swatchRGB: SIMD3<Float>)
    case freeSpace(swatchRGB: SIMD3<Float>)
    case hiddenSpace(swatchRGB: SIMD3<Float>)

    var nodeID: String? {
        switch self {
        case .node(let id, _): id
        case .aggregate(let folderID, _, _, _): folderID
        case .freeSpace, .hiddenSpace: nil
        }
    }

    var swatchRGB: SIMD3<Float> {
        switch self {
        case .node(_, let rgb), .freeSpace(let rgb), .hiddenSpace(let rgb): rgb
        case .aggregate(_, _, _, let rgb): rgb
        }
    }
}

/// Edge detector for high-frequency pointer streams. `nil` is the initial
/// off-target state, so repeated exits are no-ops just like repeated motion
/// within one identity.
struct HoverIdentityGate<ID: Equatable>: Equatable {
    private(set) var current: ID?

    mutating func transition(to next: ID?) -> Bool {
        guard current != next else { return false }
        current = next
        return true
    }
}
