//
//  SunburstChartView.swift
//  Neodisk
//
//  The composed sunburst chart: canvases under an interaction overlay,
//  pinch-to-drill navigation (DaisyDisk style), the center "go up"
//  affordance, and a delayed loading indicator. Ported from Radix; click
//  semantics (single-click drill) and model wiring live in SunburstPane.
//

import SunburstCore
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
    /// free space, hidden space); changes reload the layout. Color changes
    /// restyle the rendered segments instead (see the `style` onChange).
    let layoutID: String
    let style: SunburstColorStyle
    let freeSpaceBytes: Int64?
    let hiddenSpaceBytes: Int64?
    /// Folders whose "Smaller Items" pool the user clicked open — their
    /// children lay out individually. Part of the layout identity.
    let expandedAggregateIDs: Set<String>
    /// Formatted total size of the displayed folder, shown in the center
    /// hole (the hover-preview folder while the chart hovers a directory).
    let centerSizeText: String
    let onHoverSegment: (SunburstSegment?) -> Void
    let onClickSegment: (SunburstSegment?) -> Void
    /// A pinch-spread landed on this segment — drill into it (navigation
    /// only; no selection fallback, unlike a click).
    let onPinchDrillSegment: (SunburstSegment) -> Void
    let onNavigateToParent: () -> Void
    /// Keyboard input while the chart has key focus; returns true when
    /// handled so unhandled keys continue up the responder chain.
    let onKeyDown: (NSEvent) -> Bool
    let contextMenu: (SunburstSegment) -> NSMenu?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by SunburstPane, which shares the rendered segments with the
    /// legend list so both derive from the same layout.
    @ObservedObject var chartModel: SunburstChartModel
    @State private var isHoveringCenter = false
    @State private var showsLoadingDiskMapProgress = false
    /// The in-flight drill zoom (DaisyDisk-style); nil outside transitions.
    /// Rendering derives from this plus the TimelineView frame date.
    @State private var zoomTransition: SunburstZoomTransitionState?

    private var loadingDiskMapProgressTaskID: String {
        "\(layoutID)|\(chartModel.isLayoutPending)"
    }

    var body: some View {
        GeometryReader { geometry in
            let baseChartFrame = chartFrame(in: geometry.size)

            TimelineView(.animation(minimumInterval: nil, paused: zoomTransition == nil)) { timeline in
                accessibleChart(baseChartFrame: baseChartFrame, now: timeline.date)
            }
                .animation(chartTransitionAnimation, value: chartModel.renderedLayoutVersion)
                .animation(centerHoverAnimation, value: isHoveringCenter)
                .animation(loadingIndicatorAnimation, value: showsLoadingDiskMapProgress)
                // Fires before the layout task below replaces the rendered
                // segments, so the outgoing layout can still be captured.
                .onChange(of: layoutID) { previousLayoutID, nextLayoutID in
                    prepareZoomTransition(fromLayoutID: previousLayoutID, toLayoutID: nextLayoutID)
                }
                .onChange(of: chartModel.isLayoutPending) { _, isPending in
                    guard !isPending else { return }
                    zoomTransitionLayoutDidLand()
                }
                .task(id: zoomTransition?.id) {
                    await finalizeZoomTransition()
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
                        hiddenSpaceBytes: hiddenSpaceBytes,
                        expandedAggregateIDs: expandedAggregateIDs,
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

    private func accessibleChart(baseChartFrame: CGRect, now: Date) -> some View {
        interactiveChart(baseChartFrame: baseChartFrame, now: now)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk usage chart")
            .accessibilityValue(Text(verbatim: accessibilityValue))
            .accessibilityHint(accessibilityHint)
            // One stable identity with the action built conditionally
            // INSIDE: an if/else around the chart itself gave the two
            // branches different SwiftUI identities, so drilling away from
            // the scan root (parentNode nil → non-nil) recreated the whole
            // subtree — including the interaction overlay's NSView, which
            // silently dropped key focus mid-keyboard-navigation.
            .accessibilityActions {
                if let parentNode {
                    Button(goUpText(to: parentNode)) {
                        onNavigateToParent()
                    }
                }
            }
    }

    private func interactiveChart(baseChartFrame: CGRect, now: Date) -> some View {
        chartLayers(chartFrame: baseChartFrame, now: now)
            .contentShape(Rectangle())
            .overlay {
                interactionOverlay(baseChartFrame: baseChartFrame)
            }
            .clipped()
    }

    // MARK: - Chart layers

    @ViewBuilder
    private func chartLayers(chartFrame: CGRect, now: Date) -> some View {
        let zoomPresentation = zoomTransition.map {
            SunburstZoomPresentation(state: $0, now: now)
        }

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
            // During a zoom the transition canvas replaces the base layer
            // outright (the identity swap must not add its own fade on
            // top). Every takeover and teardown boundary lands on
            // pixel-identical content, so the swaps are invisible cuts.
            .transition(zoomTransition == nil ? chartTransition : .identity)
            .opacity(zoomTransition == nil ? 1 : 0)
            .allowsHitTesting(false)

            if let zoomTransition, let zoomPresentation {
                SunburstZoomTransitionCanvas(
                    state: zoomTransition,
                    presentation: zoomPresentation
                )
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)
            }

            if zoomPresentation == nil {
                SunburstHoverOverlay(
                    segment: chartModel.hoveredSegment
                )
                .equatable()
                .frame(width: chartFrame.width, height: chartFrame.height)
                .position(x: chartFrame.midX, y: chartFrame.midY)
                .allowsHitTesting(false)
            }

            if !chartModel.isLayoutPending, !chartModel.renderedSegments.isEmpty,
               zoomPresentation == nil {
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

            // The zoom transition already shows meaningful motion while the
            // layout loads; dimming it would read as a glitch. The timeout
            // in the transition state brings this back for slow loads.
            if chartModel.isLayoutPending, zoomPresentation == nil {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.28)
                    .allowsHitTesting(false)

                if showsLoadingDiskMapProgress {
                    ProgressView("Loading Disk Map…")
                        .controlSize(.small)
                        .transition(.opacity)
                }
            } else if !chartModel.isLayoutPending, chartModel.renderedSegments.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Interaction overlay

    @ViewBuilder
    private func interactionOverlay(baseChartFrame: CGRect) -> some View {
        let onHover: (CGPoint?) -> Void = { location in
            guard !chartModel.isLayoutPending, zoomTransition == nil else { return }
            updateHover(at: location, in: baseChartFrame)
        }
        let onClick: (CGPoint, Int) -> Void = { location, clickCount in
            guard !chartModel.isLayoutPending, zoomTransition == nil else { return }
            handleClick(at: location, in: baseChartFrame, clickCount: clickCount)
        }
        let onPinchDrill: (CGPoint, SunburstPinchDirection) -> Void = { location, direction in
            guard !chartModel.isLayoutPending, zoomTransition == nil else { return }
            handlePinchDrill(at: location, in: baseChartFrame, direction: direction)
        }
        let keyHandler: (NSEvent) -> Bool = { event in
            guard !chartModel.isLayoutPending, zoomTransition == nil else { return false }
            return onKeyDown(event)
        }
        let menuProvider: (CGPoint) -> NSMenu? = { location in
            guard !chartModel.isLayoutPending, zoomTransition == nil,
                  let segment = hitTest(at: location, in: baseChartFrame) else {
                return nil
            }
            return contextMenu(segment)
        }
        let helpProvider: (CGPoint) -> String? = { location in
            guard !chartModel.isLayoutPending, zoomTransition == nil else { return nil }
            return help(at: location, in: baseChartFrame)
        }

        SunburstInteractionOverlay(
            onHover: onHover,
            onClick: onClick,
            onPinchDrill: onPinchDrill,
            onKeyDown: keyHandler,
            contextMenu: menuProvider,
            help: helpProvider
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

    // MARK: - Zoom transition

    /// Starts the DaisyDisk-style drill zoom when the layout identity moves
    /// to a different root within the same snapshot. Drilling in animates
    /// immediately on the outgoing layout; zooming out waits for the parent
    /// layout to land and plays the reverse. Everything else (rescans,
    /// unrendered targets, Reduce Motion) keeps the plain fade.
    private func prepareZoomTransition(fromLayoutID: String, toLayoutID: String) {
        guard !reduceMotion else {
            zoomTransition = nil
            return
        }

        // layoutID is "snapshot|root|depth|freeSpace|hiddenSpace" (see
        // SunburstPane).
        let previousParts = fromLayoutID.split(separator: "|", omittingEmptySubsequences: false)
        let nextParts = toLayoutID.split(separator: "|", omittingEmptySubsequences: false)
        guard previousParts.count == 6, nextParts.count == 6,
              previousParts[0] == nextParts[0],
              previousParts[1] != nextParts[1] else {
            zoomTransition = nil
            return
        }

        let previousRootID = String(previousParts[1])
        let nextRootID = String(nextParts[1])
        let outgoingSegments = chartModel.renderedSegments
        guard !outgoingSegments.isEmpty else {
            zoomTransition = nil
            return
        }

        if let focus = chartModel.segment(forNodeID: nextRootID) {
            zoomTransition = .zoomIn(segments: outgoingSegments, focus: focus)
        } else if treeStore.isAncestor(nextRootID, of: previousRootID) {
            zoomTransition = .zoomOut(
                previousSegments: outgoingSegments,
                previousRootID: previousRootID
            )
        } else {
            zoomTransition = nil
        }
    }

    /// The drilled layout landed: zoom-in can start its end crossfade;
    /// zoom-out resolves its focus in the new layout and starts the reverse
    /// animation (or falls back to the plain swap if the outgoing root has
    /// no segment there — pooled away or beyond the depth limit).
    private func zoomTransitionLayoutDidLand() {
        guard var transition = zoomTransition, transition.layoutReadyDate == nil else { return }

        switch transition.direction {
        case .zoomIn:
            guard let focus = transition.focus else {
                zoomTransition = nil
                return
            }
            transition.incomingSegments = chartModel.renderedSegments
            transition.handoffFadeDepthThreshold = Self.handoffFadeDepthThreshold(
                animatedSegments: transition.animatedSegments,
                focus: focus
            )
            transition.layoutReadyDate = Date()
        case .zoomOut:
            guard let previousRootID = transition.previousRootID,
                  let focus = chartModel.segment(forNodeID: previousRootID),
                  !chartModel.renderedSegments.isEmpty else {
                zoomTransition = nil
                return
            }
            transition.animatedSegments = chartModel.renderedSegments
            transition.focus = focus
            transition.handoffFadeDepthThreshold = Self.handoffFadeDepthThreshold(
                animatedSegments: transition.animatedSegments,
                focus: focus
            )
            transition.layoutReadyDate = Date()
        }

        zoomTransition = transition
    }

    /// The deepest ring the remap can carry: animated ring `d` lands
    /// `focus.depth + 1` rings shallower, so anything in the other layout
    /// past this depth has no remapped counterpart and alpha-fades at the
    /// handoff (incoming deep rings on zoom-in, the outgoing chart's
    /// orphaned outermost rings on zoom-out).
    private static func handoffFadeDepthThreshold(
        animatedSegments: [SunburstSegment],
        focus: SunburstSegment
    ) -> Int {
        let maxAnimatedDepth = animatedSegments.map(\.depth).max() ?? 0
        return maxAnimatedDepth - focus.depth - 1
    }

    /// Clears the transition state once its presentation reports finished
    /// (the TimelineView pauses again and the base layer takes over at full
    /// opacity, pixel-identical to the last transition frame).
    private func finalizeZoomTransition() async {
        while let transition = zoomTransition {
            if SunburstZoomPresentation(state: transition, now: Date()).isFinished {
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        zoomTransition = nil
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

    /// Pinch-to-drill (DaisyDisk style): a spread over an arc opens that
    /// folder, a squeeze anywhere goes up one level. The center hole is not
    /// a drill target — spreading there would re-open the current root.
    private func handlePinchDrill(
        at location: CGPoint,
        in frame: CGRect,
        direction: SunburstPinchDirection
    ) {
        switch direction {
        case .drillIn:
            guard !isCenterHit(at: location, in: frame),
                  let segment = hitTest(at: location, in: frame) else { return }
            onPinchDrillSegment(segment)
        case .drillOut:
            guard parentNode != nil else { return }
            onNavigateToParent()
        }
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
        min(frame.width, frame.height) * CGFloat(SunburstLayout.centerRadius)
    }

    private func localChartPoint(
        for location: CGPoint,
        in frame: CGRect
    ) -> (point: CGPoint, size: CGSize)? {
        guard frame.contains(location) else { return nil }
        return (
            CGPoint(x: location.x - frame.minX, y: location.y - frame.minY),
            frame.size
        )
    }

    private func hitTest(at location: CGPoint, in frame: CGRect) -> SunburstSegment? {
        guard let chartPoint = localChartPoint(for: location, in: frame) else {
            return nil
        }

        return chartModel.segment(at: chartPoint.point, in: chartPoint.size)
    }

    private func isCenterHit(at location: CGPoint, in frame: CGRect) -> Bool {
        guard let chartPoint = localChartPoint(for: location, in: frame) else {
            return false
        }

        return SunburstCenterHitTester.contains(
            point: chartPoint.point,
            in: chartPoint.size
        )
    }

    private func help(at location: CGPoint, in frame: CGRect) -> String? {
        guard let parentNode, isCenterHit(at: location, in: frame) else { return nil }
        return goUpText(to: parentNode)
    }

    private func goUpText(to parentNode: FileNodeRecord) -> String {
        String(
            format: NSLocalizedString("Go up to %@", comment: "Sunburst center tooltip"),
            parentNode.name
        )
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
