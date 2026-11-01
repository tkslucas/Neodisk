import SunburstCore
import Combine
import CoreGraphics
import Foundation
import NeodiskKit
import NeodiskAppModel

/// `style` is deliberately not part of `layoutID`, so color changes restyle instead of re-laying out.
struct SunburstLayoutRequest: Sendable {
    let treeStore: FileTreeStore
    let rootID: String
    let depthLimit: Int
    let style: SunburstColorStyle
    let freeSpaceBytes: Int64?
    let hiddenSpaceBytes: Int64?
    let expandedAggregateIDs: Set<String>
    /// Whether dataless (cloud-only) bytes count toward each arc's weight —
    /// the toolbar toggle. A geometry input, so it is part of `layoutID`.
    let includeCloudOnly: Bool
    /// Identity of this layout's geometry inputs; a changed id supersedes
    /// older loads.
    let layoutID: String
}

protocol SunburstLayouting: Sendable {
    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment]
}

actor SunburstLayoutService: SunburstLayouting {
    /// Returns unstyled segments; the chart model applies the fill pass.
    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment] {
        try SunburstLayout.segments(
            in: request.treeStore,
            rootID: request.rootID,
            depthLimit: request.depthLimit,
            freeSpaceBytes: request.freeSpaceBytes,
            hiddenSpaceBytes: request.hiddenSpaceBytes,
            expandedAggregateIDs: request.expandedAggregateIDs,
            includeCloudOnly: request.includeCloudOnly,
            freeSpaceLabel: NSLocalizedString("Free Space", comment: "Sunburst free-space segment label"),
            hiddenSpaceLabel: NSLocalizedString("Hidden Space", comment: "Sunburst hidden-space segment label"),
            cancellationCheck: Task.checkCancellation
        )
    }
}

@MainActor
final class SunburstChartModel: ObservableObject {
    @Published private var renderState = SunburstChartRenderState()
    /// The root the segments on screen were laid out for.
    private(set) var drawnRootID: String?
    @Published private(set) var isLayoutPending = false

    private let layoutService: any SunburstLayouting
    private var layoutGeneration = 0
    private var activeLayoutID: String?
    private var layoutTask: Task<[SunburstSegment], Error>?
    private var selectionOverlayCache = SunburstSelectionOverlayCache(capacity: 8)
    private var cleanupOverlayCache: (key: SunburstCleanupOverlayKey, overlay: SunburstCleanupOverlay)?
    private var legendPresentationCache = SunburstLegendPresentationCache()
    /// The rendered layout before fills, kept so a style change re-resolves
    /// colors over the finished geometry instead of re-laying out.
    private var unstyledSegments: [SunburstSegment] = []
    private var currentStyle = SunburstColorStyle()

    init(layoutService: any SunburstLayouting = SunburstLayoutService()) {
        self.layoutService = layoutService
    }

    deinit {
        layoutTask?.cancel()
    }

    var renderedSegments: [SunburstSegment] {
        renderState.segments
    }

    var hoveredSegmentID: SunburstSegment.ID? {
        renderState.hoveredSegmentID
    }

    var hoveredSegment: SunburstSegment? {
        renderState.hoveredSegment
    }

    var renderedLayoutVersion: Int {
        renderState.version
    }

    func legendPresentation(
        displayedFolder: FileNodeRecord,
        chartRootID: String,
        in store: FileTreeStore,
        style: SunburstColorStyle,
        includeCloudOnly: Bool,
        expandedAggregateIDs: Set<String>,
        headerSizeOverride: Int64?
    ) -> SunburstLegendPresentation {
        let key = SunburstLegendPresentationKey(
            renderedLayoutVersion: renderedLayoutVersion,
            displayedFolderID: displayedFolder.id,
            chartRootID: chartRootID,
            style: style,
            includeCloudOnly: includeCloudOnly,
            expandedAggregateIDs: expandedAggregateIDs,
            headerSizeOverride: headerSizeOverride
        )
        return legendPresentationCache.value(for: key) {
            SunburstLegendPresentation(
                header: SunburstLegend.headerRow(
                    forFolder: displayedFolder,
                    chartRootID: chartRootID,
                    in: store,
                    segments: renderedSegments,
                    style: style,
                    includeCloudOnly: includeCloudOnly,
                    sizeOverride: headerSizeOverride
                ),
                rows: SunburstLegend.rows(
                    forFolder: displayedFolder.id,
                    chartRootID: chartRootID,
                    in: store,
                    segments: renderedSegments,
                    style: style,
                    includeCloudOnly: includeCloudOnly,
                    expandedAggregateIDs: expandedAggregateIDs
                )
            )
        }
    }

    func setHoveredSegmentID(_ segmentID: SunburstSegment.ID?) {
        guard hoveredSegmentID != segmentID else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = segmentID
        renderState = nextState
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        renderState.segment(at: point, in: size)
    }

    /// The rendered segment for a tree node, if the chart drew one — lets
    /// the legend list highlight a hovered row's arc.
    func segment(forNodeID nodeID: String) -> SunburstSegment? {
        renderState.segment(forNodeID: nodeID)
    }

    /// The rendered segment with this id (aggregate and free-space segments
    /// have no node) — legend row hover for pooled/free rows.
    func segment(forSegmentID segmentID: SunburstSegment.ID) -> SunburstSegment? {
        renderState.segment(forSegmentID: segmentID)
    }

    /// Every selected arc drawn selected; the path down to the primary one drawn as its ancestors.
    func selectionOverlaySegments(
        selection: NodeSelection,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        let key = SunburstSelectionOverlayCacheKey(
            renderVersion: renderedLayoutVersion,
            selectedNodeID: selection.primaryID,
            selectedAncestorIDs: selectedAncestorIDs,
            selectionRevision: selection.isMultiple ? selection.revision : 0
        )
        return selectionOverlayCache.segments(for: key) {
            renderState.selectionOverlaySegments(
                selection: selection,
                selectedAncestorIDs: selectedAncestorIDs
            )
        }
    }

    /// The arcs Cleanup marks over the finished layout (never a re-layout): memoized per layout and pile.
    func cleanupOverlay(collected: [String], moving: Set<String>, rootIsInside: Bool) -> SunburstCleanupOverlay {
        let key = SunburstCleanupOverlayKey(
            renderVersion: renderedLayoutVersion, collected: collected, moving: moving, rootIsInside: rootIsInside
        )
        if let cached = cleanupOverlayCache, cached.key == key { return cached.overlay }
        let overlay = SunburstCleanupOverlay(
            segments: renderedSegments,
            marks: { renderState.segment(forNodeID: $0) },
            collected: collected,
            moving: moving,
            rootIsInside: rootIsInside
        )
        cleanupOverlayCache = (key, overlay)
        return overlay
    }

    /// O(segments), never a re-layout. A load in flight picks up the latest style when it completes.
    func applyStyle(_ style: SunburstColorStyle, in treeStore: FileTreeStore) {
        guard style != currentStyle else { return }
        currentStyle = style
        guard !unstyledSegments.isEmpty else { return }
        apply(
            SunburstLayout.styled(unstyledSegments, style: style, in: treeStore),
            preservingHover: true
        )
    }

    @discardableResult
    func loadLayout(_ request: SunburstLayoutRequest) async -> Bool {
        layoutGeneration += 1
        let generation = layoutGeneration
        activeLayoutID = request.layoutID
        layoutTask?.cancel()
        clearHover()
        setIsLayoutPending(true)
        currentStyle = request.style

        let task = Task(priority: .userInitiated) { [layoutService] in
            try await layoutService.segments(for: request)
        }
        layoutTask = task

        do {
            let segments = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard isCurrentLayout(generation: generation, layoutID: request.layoutID) else {
                return false
            }

            layoutTask = nil
            unstyledSegments = segments
            // Styled with the latest style — it may have moved on (via
            // applyStyle) while the layout ran.
            apply(SunburstLayout.styled(segments, style: currentStyle, in: request.treeStore))
            drawnRootID = request.rootID
            setIsLayoutPending(false)
            return true
        } catch is CancellationError {
            guard isCurrentLayout(generation: generation, layoutID: request.layoutID) else {
                return false
            }
            layoutTask = nil
            setIsLayoutPending(false)
            return false
        } catch {
            guard isCurrentLayout(generation: generation, layoutID: request.layoutID) else {
                return false
            }
            layoutTask = nil
            // Keep the last successful geometry until a replacement succeeds.
            setIsLayoutPending(false)
            return false
        }
    }

    private func isCurrentLayout(generation: Int, layoutID: String) -> Bool {
        layoutGeneration == generation && activeLayoutID == layoutID
    }

    private func apply(_ segments: [SunburstSegment], preservingHover: Bool = false) {
        selectionOverlayCache.removeAll()
        legendPresentationCache.removeAll()
        renderState = SunburstChartRenderState(
            segments: segments,
            hoveredSegmentID: preservingHover ? renderState.hoveredSegmentID : nil,
            version: renderState.version + 1
        )
    }

    private func clearHover() {
        guard hoveredSegmentID != nil else { return }
        var nextState = renderState
        nextState.hoveredSegmentID = nil
        renderState = nextState
    }

    private func setIsLayoutPending(_ isPending: Bool) {
        guard isLayoutPending != isPending else { return }
        isLayoutPending = isPending
    }
}

private struct SunburstCleanupOverlayKey: Equatable {
    let renderVersion: Int
    let collected: [String]
    let moving: Set<String>
    let rootIsInside: Bool
}

/// Collected arcs get an outline; they and every arc inside them (by angle and ring, so pooled arcs too) get
/// the wash. A collected item the layout pooled or dropped has no arc and draws nothing.
struct SunburstCleanupOverlay: Equatable {
    var wash: [SunburstSegment] = []
    var collected: [SunburstSegment] = []
    var moving: [SunburstSegment] = []

    var isEmpty: Bool { wash.isEmpty }

    init() {}

    init(
        segments: [SunburstSegment],
        marks segment: (String) -> SunburstSegment?,
        collected collectedIDs: [String],
        moving movingIDs: Set<String>,
        rootIsInside: Bool
    ) {
        guard !segments.isEmpty, !(collectedIDs.isEmpty && movingIDs.isEmpty) else { return }
        if rootIsInside {
            // Drilled into a collected folder: everything on screen is in Cleanup.
            wash = segments
            return
        }
        moving = movingIDs.sorted().compactMap(segment)
        collected = collectedIDs.filter { !movingIDs.contains($0) }.compactMap(segment)
        let marked = moving + collected
        guard !marked.isEmpty else { return }
        let epsilon = 1e-9
        wash = segments.filter { candidate in
            marked.contains { mark in
                candidate.innerRadius >= mark.innerRadius - epsilon
                    && candidate.startAngle >= mark.startAngle - epsilon
                    && candidate.endAngle <= mark.endAngle + epsilon
            }
        }
    }
}

private struct SunburstSelectionOverlayCacheKey: Hashable {
    let renderVersion: Int
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
    /// A multi-selection's members aren't in the key; its revision stands for them.
    let selectionRevision: UInt64
}

private struct SunburstSelectionOverlayCache {
    private let capacity: Int
    private var segmentsByKey: [SunburstSelectionOverlayCacheKey: [SunburstSelectionOverlaySegment]] = [:]
    private var keysByRecency: [SunburstSelectionOverlayCacheKey] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    mutating func segments(
        for key: SunburstSelectionOverlayCacheKey,
        build: () -> [SunburstSelectionOverlaySegment]
    ) -> [SunburstSelectionOverlaySegment] {
        if let segments = segmentsByKey[key] {
            markRecentlyUsed(key)
            return segments
        }

        let segments = build()
        segmentsByKey[key] = segments
        markRecentlyUsed(key)
        trimToCapacity()
        return segments
    }

    mutating func removeAll() {
        segmentsByKey.removeAll()
        keysByRecency.removeAll()
    }

    private mutating func markRecentlyUsed(_ key: SunburstSelectionOverlayCacheKey) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private mutating func trimToCapacity() {
        while segmentsByKey.count > capacity, let oldestKey = keysByRecency.first {
            keysByRecency.removeFirst()
            segmentsByKey[oldestKey] = nil
        }
    }
}

enum SunburstSelectionRole: Equatable, Sendable {
    case ancestor
    case selected
}

struct SunburstSelectionOverlaySegment: Identifiable, Equatable, Sendable {
    let segment: SunburstSegment
    let role: SunburstSelectionRole

    var id: SunburstSegment.ID {
        segment.id
    }
}

private struct SunburstChartRenderState {
    var segments: [SunburstSegment]
    var hoveredSegmentID: SunburstSegment.ID?
    var version: Int

    private var segmentLookup: [SunburstSegment.ID: SunburstSegment]
    private var segmentByNodeID: [String: SunburstSegment]
    private var hitTestIndex: SunburstHitTestIndex

    init(
        segments: [SunburstSegment] = [],
        hoveredSegmentID: SunburstSegment.ID? = nil,
        version: Int = 0
    ) {
        self.segments = segments
        self.hoveredSegmentID = hoveredSegmentID
        self.version = version
        segmentLookup = segments.reduce(into: [:]) { lookup, segment in
            lookup[segment.id] = segment
        }
        segmentByNodeID = segments.reduce(into: [:]) { lookup, segment in
            guard let nodeID = segment.nodeID else { return }
            lookup[nodeID] = segment
        }
        hitTestIndex = SunburstHitTestIndex(segments: segments)
    }

    var hoveredSegment: SunburstSegment? {
        guard let hoveredSegmentID else { return nil }
        return segmentLookup[hoveredSegmentID]
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        hitTestIndex.segment(at: point, in: size)
    }

    func segment(forNodeID nodeID: String) -> SunburstSegment? {
        segmentByNodeID[nodeID]
    }

    func segment(forSegmentID segmentID: SunburstSegment.ID) -> SunburstSegment? {
        segmentLookup[segmentID]
    }

    func selectionOverlaySegments(
        selection: NodeSelection,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        guard let selectedNodeID = selection.primaryID else { return [] }

        var overlaySegments: [SunburstSelectionOverlaySegment] = []
        overlaySegments.reserveCapacity(selectedAncestorIDs.count + selection.count)

        // An ancestor that is itself selected draws as selected, below.
        for segment in segments {
            guard let nodeID = segment.nodeID,
                  nodeID != selectedNodeID,
                  selectedAncestorIDs.contains(nodeID),
                  !selection.contains(nodeID) else {
                continue
            }

            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: segment,
                role: .ancestor
            ))
        }

        // The primary last, so it draws on top.
        for nodeID in selection.ids where nodeID != selectedNodeID {
            if let segment = segmentByNodeID[nodeID] {
                overlaySegments.append(SunburstSelectionOverlaySegment(segment: segment, role: .selected))
            }
        }
        if let selectedSegment = segmentByNodeID[selectedNodeID] {
            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: selectedSegment,
                role: .selected
            ))
        }

        return overlaySegments
    }
}
