//
//  SunburstColorResolver.swift
//  Neodisk
//
//  The SwiftUI Color layer over SunburstCore's pure branch-hue math: turns a
//  color token (or an arbitrary node's branch color, for the status-bar
//  swatch) into a Color. The HSB/RGB math and FNV hashing live in SunburstCore.
//

import SwiftUI
import NeodiskKit
import SunburstCore

extension SunburstColorComponents {
    nonisolated var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

extension SunburstColorResolver {
    nonisolated static func color(
        for token: SunburstColorToken,
        palette: VizPalette = .standard
    ) -> Color {
        components(for: token, palette: palette.sunburst).color
    }

    /// The color the sunburst's branch mode draws an arbitrary node with —
    /// the status-bar swatch must agree with the chart. `effectiveRootID` is
    /// the drilled-in root: segment depth is measured from it, while the hue
    /// family always derives from the scan-root branch.
    nonisolated static func branchColor(
        forNodeID nodeID: String,
        in treeStore: FileTreeStore,
        effectiveRootID: String,
        palette: VizPalette = .standard
    ) -> Color {
        let branchID = SunburstLayout.topLevelBranchID(for: nodeID, in: treeStore) ?? nodeID
        let depth = max(
            treeStore.path(to: nodeID).count - treeStore.path(to: effectiveRootID).count - 1,
            0
        )
        let token = SunburstColorToken(
            branchID: branchID,
            localID: nodeID,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: treeStore.node(id: nodeID)?.isSunburstFolder(in: treeStore) == false ? .file : .normal
        )
        return color(for: token, palette: palette)
    }
}
