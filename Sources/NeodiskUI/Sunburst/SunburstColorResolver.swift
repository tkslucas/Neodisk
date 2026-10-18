import SwiftUI
import NeodiskKit
import SunburstCore
import NeodiskAppModel

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

    /// Scan-root anchored so the status-bar swatch agrees with the chart and never changes on drill.
    /// `branchTintedFiles` tints files for the flat treemap, where gray would wash out the mostly-file area.
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
