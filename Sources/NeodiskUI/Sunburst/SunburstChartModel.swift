//
//  SunburstChartModel.swift
//  Neodisk
//
//  Off-main sunburst layout with stale-result protection, plus the rendered
//  segment state (hover, hit-test index, selection overlay cache). Ported
//  from Radix; layout requests carry Neodisk's color style and free space.
//

import Combine
import CoreGraphics
import Foundation
import NeodiskKit

/// Everything one sunburst layout needs, bundled Sendable so the layout can
/// run detached from the main actor. `style` colors the finished layout —
/// it is deliberately not part of `layoutID`, so color changes restyle the
/// rendered segments (`applyStyle`) instead of re-laying the chart out.
struct SunburstLayoutRequest: Sendable {
    let treeStore: FileTreeStore
    let rootID: String
    let depthLimit: Int
    let style: SunburstColorStyle
    let freeSpaceBytes: Int64?
    let hiddenSpaceBytes: Int64?
    let expandedAggregateIDs: Set<String>
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
            cancellationCheck: Task.checkCancellation
        )
    }
}

@MainActor
final class SunburstChartModel: ObservableObject {
    @Published private var renderState = SunburstChartRenderState()
    @Published private(set) var isLayoutPending = false

    private let layoutService: any SunburstLayouting
    private var layoutGeneration = 0
    private var activeLayoutID: String?
    private var layoutTask: Task<[SunburstSegment], Error>?
    private var selectionOverlayCache = SunburstSelectionOverlayCache(capacity: 8)
    /// The rendered layout before fills, kept so a style change re-resolves
    /// colors over the finished geometry instead of re-laying out.
    private var unstyledSegments: [SunburstSegment] = []
    private var currentStyle = SunburstColorStyle()
    private var styleStore: FileTreeStore?

    init(layoutService: any SunburstLayouting = SunburstLayoutService()) {
        self.layoutService = layoutService
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

    func selectionOverlaySegments(
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        let key = SunburstSelectionOverlayCacheKey(
            renderVersion: renderedLayoutVersion,
            selectedNodeID: selectedNodeID,
            selectedAncestorIDs: selectedAncestorIDs
        )
        return selectionOverlayCache.segments(for: key) {
            renderState.selectionOverlaySegments(
                selectedNodeID: selectedNodeID,
                selectedAncestorIDs: selectedAncestorIDs
            )
        }
    }

    /// Recolors the rendered layout for a new style — O(segments), never a
    /// re-layout. No-op until a layout has landed; a load in flight picks
    /// the latest style up when it completes. Hover survives (the segment
    /// ids are unchanged).
    func applyStyle(_ style: SunburstColorStyle, in treeStore: FileTreeStore) {
        styleStore = treeStore
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
        styleStore = request.treeStore

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
            unstyledSegments = []
            apply([])
            setIsLayoutPending(false)
            return true
        }
    }

    private func isCurrentLayout(generation: Int, layoutID: String) -> Bool {
        layoutGeneration == generation && activeLayoutID == layoutID
    }

    private func apply(_ segments: [SunburstSegment], preservingHover: Bool = false) {
        selectionOverlayCache.removeAll()
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

private struct SunburstSelectionOverlayCacheKey: Hashable {
    let renderVersion: Int
    let selectedNodeID: String?
    let selectedAncestorIDs: Set<String>
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
        selectedNodeID: String?,
        selectedAncestorIDs: Set<String>
    ) -> [SunburstSelectionOverlaySegment] {
        guard let selectedNodeID else { return [] }

        var overlaySegments: [SunburstSelectionOverlaySegment] = []
        overlaySegments.reserveCapacity(selectedAncestorIDs.count)

        for segment in segments {
            guard let nodeID = segment.nodeID,
                  nodeID != selectedNodeID,
                  selectedAncestorIDs.contains(nodeID) else {
                continue
            }

            overlaySegments.append(SunburstSelectionOverlaySegment(
                segment: segment,
                role: .ancestor
            ))
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
