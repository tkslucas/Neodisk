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
    /// family always derives from the scan-root branch. `branchTintedFiles`
    /// selects the flat treemap's file treatment (the full folder formula —
    /// a treemap's area is mostly file tiles, gray would wash it out); the
    /// sunburst keeps its file gray. The flat treemap also measures depth
    /// from the SCAN root (drilling never re-brightens) and grays loose
    /// scan-root files (no family of their own), so this mirrors both.
    nonisolated static func branchColor(
        forNodeID nodeID: String,
        in treeStore: FileTreeStore,
        effectiveRootID: String,
        palette: VizPalette = .standard,
        branchTintedFiles: Bool = false
    ) -> Color {
        let branchID = SunburstLayout.topLevelBranchID(for: nodeID, in: treeStore) ?? nodeID
        let depthRootID = branchTintedFiles ? treeStore.root.id : effectiveRootID
        var depth = max(
            treeStore.path(to: nodeID).count - treeStore.path(to: depthRootID).count - 1,
            0
        )
        let isFile = treeStore.node(id: nodeID)?.isSunburstFolder(in: treeStore) == false
        let isLooseRootFile = isFile && depth == 0
        if branchTintedFiles, isLooseRootFile { depth = 1 }
        let token = SunburstColorToken(
            branchID: branchID,
            localID: nodeID,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: isFile && (!branchTintedFiles || isLooseRootFile) ? .file : .normal
        )
        if branchTintedFiles {
            // Mirror the flat treemap's calm-down (TreemapScene.resolvedRGB):
            // colored tiles desaturate, loose scan-root files dim.
            let comps = components(for: token, palette: palette.sunburst)
            if token.role == .file {
                return SunburstColorComponents(
                    hue: comps.hue,
                    saturation: comps.saturation,
                    brightness: comps.brightness * Double(TreemapScene.flatRootFileDim)
                ).color
            }
            return SunburstColorComponents(
                hue: comps.hue,
                saturation: comps.saturation * Double(1 - TreemapScene.flatBranchDesaturation),
                brightness: comps.brightness
            ).color
        }
        return color(for: token, palette: palette)
    }
}
