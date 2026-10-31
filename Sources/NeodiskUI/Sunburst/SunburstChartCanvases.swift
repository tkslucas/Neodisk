// Base rings are Equatable on the render version, so unrelated view updates skip redrawing.

import SunburstCore
import SwiftUI

struct SunburstBaseCanvas: View, Equatable {
    let segments: [SunburstSegment]
    let renderVersion: Int

    nonisolated static func == (lhs: SunburstBaseCanvas, rhs: SunburstBaseCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
    }

    var body: some View {
        Canvas { context, size in
            // Cloud-only arcs collect into one region so the hatch pass
            // clips and strokes once, not per arc.
            var datalessRegion = Path()
            for segment in segments {
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.baseStyle(for: segment)
                context.fill(path, with: .color(style.fillColor))
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
                if segment.isDataless {
                    datalessRegion.addPath(path)
                }
            }
            if !datalessRegion.isEmpty {
                SunburstDatalessHatch(size: size).draw(over: datalessRegion, in: context)
            }
        }
    }
}

struct SunburstSelectionOverlay: View, Equatable {
    let segments: [SunburstSelectionOverlaySegment]

    nonisolated static func == (lhs: SunburstSelectionOverlay, rhs: SunburstSelectionOverlay) -> Bool {
        lhs.segments == rhs.segments
    }

    var body: some View {
        Canvas { context, size in
            for overlaySegment in segments {
                let segment = overlaySegment.segment
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.selectionOverlayStyle(
                    for: segment,
                    role: overlaySegment.role
                )
                if style.fillOpacity > 0 {
                    context.fill(path, with: .color(style.fillColor))
                }
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct SunburstHoverOverlay: View, Equatable {
    let segment: SunburstSegment?

    nonisolated static func == (lhs: SunburstHoverOverlay, rhs: SunburstHoverOverlay) -> Bool {
        lhs.segment == rhs.segment
    }

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }

            let path = SunburstRenderer.path(for: segment, in: size)
            let style = SunburstChartStyler.hoverOverlayStyle(for: segment)
            if style.fillOpacity > 0 {
                context.fill(path, with: .color(style.fillColor))
            }
            context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
        }
    }
}

/// Cleanup marks over the rings: a wash toward the window background on collected arcs and what's inside them,
/// then a halo and a dashed accent outline (solid secondary while moving). The same language as the treemap's.
struct SunburstCleanupOverlayCanvas: View, Equatable {
    let overlay: SunburstCleanupOverlay

    nonisolated static func == (lhs: SunburstCleanupOverlayCanvas, rhs: SunburstCleanupOverlayCanvas) -> Bool {
        lhs.overlay == rhs.overlay
    }

    var body: some View {
        Canvas { context, size in
            guard !overlay.isEmpty else { return }
            let background = Color(nsColor: .windowBackgroundColor)
            var wash = Path()
            for segment in overlay.wash {
                wash.addPath(SunburstRenderer.path(for: segment, in: size))
            }
            context.fill(wash, with: .color(background.opacity(0.6)))

            let outlined = overlay.moving + overlay.collected
            for segment in outlined {
                context.stroke(
                    SunburstRenderer.path(for: segment, in: size),
                    with: .color(background.opacity(0.85)),
                    lineWidth: 3
                )
            }
            for segment in overlay.collected {
                context.stroke(
                    SunburstRenderer.path(for: segment, in: size),
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [5, 3])
                )
            }
            for segment in overlay.moving {
                context.stroke(
                    SunburstRenderer.path(for: segment, in: size),
                    with: .color(.secondary),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                )
            }
        }
    }
}
