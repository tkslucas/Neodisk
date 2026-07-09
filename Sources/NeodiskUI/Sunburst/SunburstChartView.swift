//
//  SunburstChartView.swift
//  Neodisk
//
//  The composed sunburst chart: canvases under an interaction overlay, a
//  viewport transform for pinch/scroll zoom and pan, the center "go up"
//  affordance, and a delayed loading indicator. Ported from Radix; click
//  semantics (single-click drill) and model wiring live in SunburstPane.
//

import AppKit
import SwiftUI
import NeodiskKit

struct SunburstChartView: View {
    private static let chartPadding: CGFloat = 22
    private static let loadingDiskMapDelay: Duration = .milliseconds(150)

    let rootNode: FileNodeRecord
    /// The drilled-in root's parent within the store; nil at the scan root.
    /// Non-nil enables the center "go up" affordance and click.
    let parentNode: FileNodeRecord?
    let treeStore: FileTreeStore
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    let depthLimit: Int
    /// Identity of the layout's geometry inputs (snapshot, root, depth,
    /// free space); changes reload the layout. Color changes restyle the
    /// rendered segments instead (see the `style` onChange).
    let layoutID: String
    /// Identity of the displayed root only; changes reset the viewport, so
    /// tab/palette switches keep the user's zoom.
    let viewportResetID: String
    let style: SunburstColorStyle
    let freeSpaceBytes: Int64?
    /// Formatted total size of the displayed folder, shown in the center
    /// hole (the hover-preview folder while the chart hovers a directory).
    let centerSizeText: String
    let onHoverSegment: (SunburstSegment?) -> Void
    let onClickSegment: (SunburstSegment?) -> Void
    let onNavigateToParent: () -> Void
    let contextMenu: (SunburstSegment) -> NSMenu?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by SunburstPane, which shares the rendered segments with the
    /// legend list so both derive from the same layout.
    @ObservedObject var chartModel: SunburstChartModel
    @State private var isHoveringCenter = false
    @State private var showsLoadingDiskMapProgress = false
    @State private var viewportTransform = SunburstViewportTransform.identity

    private var canAdjustViewport: Bool {
        !chartModel.isLayoutPending && !chartModel.renderedSegments.isEmpty
    }

    private var loadingDiskMapProgressTaskID: String {
        "\(layoutID)|\(chartModel.isLayoutPending)"
    }

    var body: some View {
        GeometryReader { geometry in
            let baseChartFrame = chartFrame(in: geometry.size)

            accessibleChart(baseChartFrame: baseChartFrame)
                .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
                .animation(centerHoverAnimation, value: isHoveringCenter)
                .animation(loadingIndicatorAnimation, value: showsLoadingDiskMapProgress)
                .onChange(of: baseChartFrame) { _, nextFrame in
                    viewportTransform = viewportTransform.constrained(to: nextFrame)
                }
                .onChange(of: viewportResetID) { _, _ in
                    resetViewport(animated: false)
                }
                .task(id: loadingDiskMapProgressTaskID) {
                    await updateLoadingDiskMapProgress(isPending: chartModel.isLayoutPending)
                }
                .task(id: layoutID) {
                    await chartModel.loadLayout(SunburstLayoutRequest(
                        treeStore: treeStore,
                        rootID: rootNode.id,
                        depthLimit: depthLimit,
                        style: style,
                        freeSpaceBytes: freeSpaceBytes,
                        layoutID: layoutID
                    ))
                }
                // Tab, palette, highlight, and catalog changes recolor the
                // finished layout — O(segments), never a re-layout.
                .onChange(of: style) { _, nextStyle in
                    chartModel.applyStyle(nextStyle, in: treeStore)
                }
        }
    }

    private func accessibleChart(baseChartFrame: CGRect) -> some View {
        interactiveChart(baseChartFrame: baseChartFrame)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(Text(verbatim: accessibilityValue))
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: "Zoom In") {
                zoomViewport(by: 1.25, anchor: nil, in: baseChartFrame, animated: true)
            }
            .accessibilityAction(named: "Zoom Out") {
                zoomViewport(by: 0.8, anchor: nil, in: baseChartFrame, animated: true)
            }
            .accessibilityAction(named: "Reset Zoom") {
                resetViewport(animated: true)
            }
    }

    private func interactiveChart(baseChartFrame: CGRect) -> some View {
        chartLayers(chartFrame: viewportTransform.frame(for: baseChartFrame))
            .contentShape(Rectangle())
            .overlay {
                interactionOverlay(
                    baseChartFrame: baseChartFrame,
                    canAdjustViewport: canAdjustViewport
                )
            }
            .clipped()
    }

    // MARK: - Chart layers

    @ViewBuilder
    private func chartLayers(chartFrame: CGRect) -> some View {
        ZStack {
            SunburstRenderedChartLayer(
                segments: chartModel.renderedSegments,
                renderVersion: chartModel.renderedLayoutVersion,
                selectionSegments: chartModel.selectionOverlaySegments(
                    selectedNodeID: selectedNodeID,
                    selectedAncestorIDs: selectedAncestorIDs
                ),
                chartFrame: chartFrame
            )
            .id(chartModel.renderedLayoutVersion)
            .transition(chartTransition)
            .allowsHitTesting(false)

            SunburstHoverOverlay(
                segment: chartModel.hoveredSegment
            )
            .equatable()
            .frame(width: chartFrame.width, height: chartFrame.height)
            .position(x: chartFrame.midX, y: chartFrame.midY)
            .allowsHitTesting(false)

            if !chartModel.isLayoutPending, !chartModel.renderedSegments.isEmpty {
                if parentNode != nil, isHoveringCenter {
                    // The "go up" affordance takes the hole over while the
                    // cursor is on it; the size text returns on exit.
                    SunburstCenterAffordance()
                        .equatable()
                        .frame(
                            width: centerAffordanceSize(in: chartFrame),
                            height: centerAffordanceSize(in: chartFrame)
                        )
                        .position(x: chartFrame.midX, y: chartFrame.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else {
                    Text(verbatim: centerSizeText)
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .frame(width: centerAffordanceSize(in: chartFrame) * 0.9)
                        .position(x: chartFrame.midX, y: chartFrame.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }

            if chartModel.isLayoutPending {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.28)
                    .allowsHitTesting(false)

                if showsLoadingDiskMapProgress {
                    ProgressView("Loading Disk Map…")
                        .controlSize(.small)
                        .transition(.opacity)
                }
            } else if chartModel.renderedSegments.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Interaction overlay

    @ViewBuilder
    private func interactionOverlay(
        baseChartFrame: CGRect,
        canAdjustViewport: Bool
    ) -> some View {
        let onHover: (CGPoint?) -> Void = { location in
            guard !chartModel.isLayoutPending else { return }
            updateHover(at: location, in: baseChartFrame)
        }
        let onClick: (CGPoint, Int) -> Void = { location, clickCount in
            guard !chartModel.isLayoutPending else { return }
            handleClick(at: location, in: baseChartFrame, clickCount: clickCount)
        }
        let onPan: (CGSize) -> Void = { delta in
            panViewport(by: delta, in: baseChartFrame)
        }
        let onMagnify: (CGPoint, CGFloat) -> Void = { location, factor in
            zoomViewport(by: factor, anchor: location, in: baseChartFrame, animated: false)
        }
        let canStartPanProvider: (CGPoint) -> Bool = { location in
            canStartPan(at: location, in: baseChartFrame)
        }
        let menuProvider: (CGPoint) -> NSMenu? = { location in
            guard !chartModel.isLayoutPending,
                  let segment = hitTest(at: location, in: baseChartFrame) else {
                return nil
            }
            return contextMenu(segment)
        }
        let helpProvider: (CGPoint) -> String? = { location in
            guard !chartModel.isLayoutPending else { return nil }
            return help(at: location, in: baseChartFrame)
        }

        SunburstInteractionOverlay(
            onHover: onHover,
            onClick: onClick,
            onPan: onPan,
            onMagnify: onMagnify,
            canStartPan: canStartPanProvider,
            contextMenu: menuProvider,
            help: helpProvider,
            isPanEnabled: canAdjustViewport && viewportTransform.isZoomed
        )
        .accessibilityHidden(true)
        .allowsHitTesting(!chartModel.isLayoutPending)
    }

    // MARK: - Animations

    private var chartTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.985, anchor: .center))
    }

    private var chartTransitionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.22)
    }

    private var centerHoverAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
    }

    private var loadingIndicatorAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
    }

    private var viewportAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16)
    }

    // MARK: - Hover & click

    private func updateHover(at location: CGPoint?, in frame: CGRect) {
        guard let location else {
            isHoveringCenter = false
            chartModel.setHoveredSegmentID(nil)
            onHoverSegment(nil)
            return
        }

        if parentNode != nil, isCenterHit(at: location, in: frame) {
            isHoveringCenter = true
            chartModel.setHoveredSegmentID(nil)
            onHoverSegment(nil)
            return
        }

        isHoveringCenter = false
        let nextSegment = hitTest(at: location, in: frame)
        chartModel.setHoveredSegmentID(nextSegment?.id)
        onHoverSegment(nextSegment)
    }

    private func handleClick(at location: CGPoint, in frame: CGRect, clickCount: Int) {
        guard clickCount == 1 else { return }

        if isCenterHit(at: location, in: frame) {
            if parentNode != nil {
                onNavigateToParent()
            }
            return
        }

        onClickSegment(hitTest(at: location, in: frame))
    }

    // MARK: - Accessibility

    private var accessibilityValue: String {
        "\(rootNode.name), \(NeodiskFormatters.size(rootNode.allocatedSize))"
    }

    private var accessibilityHint: LocalizedStringKey {
        if parentNode != nil {
            return "Click a folder segment to open it. Click a file segment to select it. Click the center to go up."
        }

        return "Click a folder segment to open it. Click a file segment to select it."
    }

    // MARK: - Geometry helpers

    private func chartFrame(in size: CGSize) -> CGRect {
        let inset = Self.chartPadding
        let width = max(1, size.width - (inset * 2))
        let height = max(1, size.height - (inset * 2))
        let chartSide = min(width, height)

        return CGRect(
            x: inset + ((width - chartSide) / 2),
            y: inset + ((height - chartSide) / 2),
            width: chartSide,
            height: chartSide
        )
    }

    private func centerAffordanceSize(in frame: CGRect) -> CGFloat {
        min(frame.width, frame.height) * SunburstLayout.centerRadius
    }

    private func hitTest(at location: CGPoint, in frame: CGRect) -> SunburstSegment? {
        guard let chartPoint = viewportTransform.localChartPoint(for: location, in: frame) else {
            return nil
        }

        return chartModel.segment(at: chartPoint.point, in: chartPoint.size)
    }

    private func canStartPan(at location: CGPoint, in frame: CGRect) -> Bool {
        !isCenterHit(at: location, in: frame) && hitTest(at: location, in: frame) == nil
    }

    private func isCenterHit(at location: CGPoint, in frame: CGRect) -> Bool {
        guard let chartPoint = viewportTransform.localChartPoint(for: location, in: frame) else {
            return false
        }

        return SunburstCenterHitTester.contains(
            point: chartPoint.point,
            in: chartPoint.size
        )
    }

    private func help(at location: CGPoint, in frame: CGRect) -> String? {
        guard let parentNode, isCenterHit(at: location, in: frame) else { return nil }
        return String(
            format: NSLocalizedString("Go up to %@", comment: "Sunburst center tooltip"),
            parentNode.name
        )
    }

    // MARK: - Viewport

    private func zoomViewport(
        by factor: CGFloat,
        anchor: CGPoint?,
        in baseFrame: CGRect,
        animated: Bool
    ) {
        guard canAdjustViewport else { return }

        setViewportTransform(
            viewportTransform.zoomed(
                by: factor,
                anchor: anchor,
                in: baseFrame
            ),
            animated: animated
        )
    }

    private func panViewport(by delta: CGSize, in baseFrame: CGRect) {
        guard canAdjustViewport else { return }

        setViewportTransform(
            viewportTransform.panned(by: delta, in: baseFrame),
            animated: false
        )
    }

    private func resetViewport(animated: Bool) {
        setViewportTransform(.identity, animated: animated)
    }

    private func setViewportTransform(
        _ nextTransform: SunburstViewportTransform,
        animated: Bool
    ) {
        guard viewportTransform != nextTransform else { return }

        let update = {
            viewportTransform = nextTransform
        }

        if animated {
            withAnimation(viewportAnimation, update)
        } else {
            update()
        }
    }

    private func updateLoadingDiskMapProgress(isPending: Bool) async {
        guard isPending else {
            showsLoadingDiskMapProgress = false
            return
        }

        showsLoadingDiskMapProgress = false

        do {
            try await Task.sleep(for: Self.loadingDiskMapDelay)
        } catch {
            return
        }

        guard chartModel.isLayoutPending else { return }
        showsLoadingDiskMapProgress = true
    }
}

private struct SunburstCenterAffordance: View, Equatable {
    nonisolated static func == (lhs: SunburstCenterAffordance, rhs: SunburstCenterAffordance) -> Bool {
        true
    }

    var body: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .shadow(color: Color.black.opacity(0.14), radius: 2, y: 1)
    }
}

private struct SunburstRenderedChartLayer: View {
    let segments: [SunburstSegment]
    let renderVersion: Int
    let selectionSegments: [SunburstSelectionOverlaySegment]
    let chartFrame: CGRect

    var body: some View {
        ZStack {
            SunburstBaseCanvas(
                segments: segments,
                renderVersion: renderVersion
            )
            .equatable()

            SunburstSelectionOverlay(segments: selectionSegments)
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: chartFrame.width, height: chartFrame.height)
        .position(x: chartFrame.midX, y: chartFrame.midY)
        .compositingGroup()
    }
}
