//
//  SunburstColorResolver.swift
//  Neodisk
//
//  The SwiftUI Color layer over SunburstCore's pure midpoint-hue math: turns
//  a color token (or an arbitrary node's branch color, for the status-bar
//  swatch) into a Color. The HSB/RGB math lives in SunburstCore.
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
    /// the status-bar swatch must agree with the chart. The token derives
    /// from the node's global color coordinate (scan-root anchored, so the
    /// swatch never changes when the view drills). `includingCloudOnly`
    /// must match the chart's weighting — it moves every interval.
    /// `branchTintedFiles` selects the flat treemap's file treatment (the
    /// full folder formula — a treemap's area is mostly file tiles, gray
    /// would wash it out); the sunburst keeps its file gray. Loose
    /// scan-root files gray in both (no family of their own).
    nonisolated static func branchColor(
        forNodeID nodeID: String,
        in treeStore: FileTreeStore,
        palette: VizPalette = .standard,
        includingCloudOnly: Bool = false,
        branchTintedFiles: Bool = false
    ) -> Color {
        let coordinate = SunburstLayout.colorCoordinate(
            for: nodeID, in: treeStore, includeCloudOnly: includingCloudOnly
        ) ?? (start: 0, span: 1, depth: 0)
        let isFile = treeStore.node(id: nodeID)?.isSunburstFolder(in: treeStore) == false
        let isLooseRootFile = isFile && coordinate.depth <= 1
        let token = SunburstColorToken(
            midpoint: coordinate.start + coordinate.span / 2,
            depth: coordinate.depth,
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
