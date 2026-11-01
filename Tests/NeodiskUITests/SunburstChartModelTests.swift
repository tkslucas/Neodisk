// Generation-guarded layout loads, hover clearing and selection overlay ordering.

import SunburstCore
import Combine
import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI
@testable import NeodiskAppModel

@MainActor
@Suite(.serialized) struct SunburstChartModelTests {
    @Test func startingLayoutPublishesPendingState() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)
        let request = makeRequest(layoutID: "layout")
        var publishCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            publishCount += 1
        }

        let layoutTask = Task {
            await model.loadLayout(request)
        }
        await service.waitForIssuedRequestCount(1)

        #expect(model.isLayoutPending)
        #expect(publishCount >= 1)

        let segment = makeSegment(id: "segment")
        let didCompleteRequest = await service.completeRequest(id: 0, with: [segment])
        #expect(didCompleteRequest)
        let didApplyLayout = await layoutTask.value

        #expect(didApplyLayout)
        #expect(!model.isLayoutPending)
        #expect(model.renderedSegments.map(\.id) == [segment.id])
        #expect(publishCount >= 2)
        withExtendedLifetime(cancellable) {}
    }

    @Test func startingNewLayoutCancelsPreviousLayoutWork() async {
        let service = ControllableSunburstLayoutService(resumesOnCancellation: true)
        let model = SunburstChartModel(layoutService: service)

        let oldTask = Task {
            await model.loadLayout(makeRequest(layoutID: "old"))
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(makeRequest(layoutID: "new"))
        }
        await service.waitForCancelledRequest(id: 0)
        await service.waitForIssuedRequestCount(2)

        let didApplyOldLayout = await oldTask.value
        #expect(!didApplyOldLayout)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        #expect(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        #expect(didApplyNewLayout)
        #expect(model.renderedSegments.map(\.id) == [newSegment.id])
    }

    @Test func startingNewLayoutClearsHoverState() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)

        let firstTask = Task {
            await model.loadLayout(makeRequest(layoutID: "old"))
        }
        await service.waitForIssuedRequestCount(1)

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteFirstRequest = await service.completeRequest(id: 0, with: [oldSegment])
        #expect(didCompleteFirstRequest)
        let didApplyFirstLayout = await firstTask.value
        #expect(didApplyFirstLayout)
        model.setHoveredSegmentID(oldSegment.id)
        #expect(model.hoveredSegmentID == oldSegment.id)

        let secondTask = Task {
            await model.loadLayout(makeRequest(layoutID: "new"))
        }
        await service.waitForIssuedRequestCount(2)

        #expect(model.hoveredSegmentID == nil)
        #expect(model.isLayoutPending)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteSecondRequest = await service.completeRequest(id: 1, with: [newSegment])
        #expect(didCompleteSecondRequest)
        let didApplySecondLayout = await secondTask.value
        #expect(didApplySecondLayout)
    }

    @Test func staleLayoutResultDoesNotReplaceNewerSegments() async {
        let service = ControllableSunburstLayoutService()
        let model = SunburstChartModel(layoutService: service)

        let oldTask = Task {
            await model.loadLayout(makeRequest(layoutID: "old"))
        }
        await service.waitForIssuedRequestCount(1)

        let newTask = Task {
            await model.loadLayout(makeRequest(layoutID: "new"))
        }
        await service.waitForIssuedRequestCount(2)

        let newSegment = makeSegment(id: "new-segment")
        let didCompleteNewRequest = await service.completeRequest(id: 1, with: [newSegment])
        #expect(didCompleteNewRequest)
        let didApplyNewLayout = await newTask.value
        #expect(didApplyNewLayout)
        #expect(model.renderedSegments.map(\.id) == [newSegment.id])

        let oldSegment = makeSegment(id: "old-segment")
        let didCompleteOldRequest = await service.completeRequest(id: 0, with: [oldSegment])
        #expect(didCompleteOldRequest)
        let didApplyOldLayout = await oldTask.value
        #expect(!didApplyOldLayout)
        #expect(model.renderedSegments.map(\.id) == [newSegment.id])
    }

    @Test func failedReplacementKeepsLastRenderedLayout() async {
        let service = FailingReplacementLayoutService(segment: makeSegment(id: "retained"))
        let model = SunburstChartModel(layoutService: service)
        #expect(await model.loadLayout(makeRequest(layoutID: "first")))
        let version = model.renderedLayoutVersion
        #expect(!(await model.loadLayout(makeRequest(layoutID: "failed"))))
        #expect(model.renderedSegments.map(\.id) == ["retained"])
        #expect(model.renderedLayoutVersion == version)
        #expect(!model.isLayoutPending)
        #expect(await model.loadLayout(makeRequest(layoutID: "retry")))
    }

    @Test func selectionOverlaySegmentsIncludeAncestorsAndSelectedLast() async {
        let ancestor = makeSegment(id: "ancestor", depth: 0)
        let selected = makeSegment(id: "selected", depth: 1)
        let sibling = makeSegment(id: "sibling", depth: 1)
        let service = ImmediateSunburstLayoutService(segments: [ancestor, selected, sibling])
        let model = SunburstChartModel(layoutService: service)

        let didApplyLayout = await model.loadLayout(makeRequest(layoutID: "layout"))

        #expect(didApplyLayout)
        let overlaySegments = model.selectionOverlaySegments(
            selection: NodeSelection([selected.nodeID!]),
            selectedAncestorIDs: Set([ancestor.nodeID!, selected.nodeID!, "missing"])
        )

        #expect(overlaySegments.map(\.segment.id) == [ancestor.id, selected.id])
        #expect(overlaySegments.map(\.role) == [.ancestor, .selected])
    }

    /// Every selected arc draws selected (the primary last, on top); only the primary's path draws as
    /// ancestors, and an ancestor that is itself selected draws selected.
    @Test func multiSelectionDrawsEveryArcAndOnlyThePrimarysPath() async {
        let ancestor = makeSegment(id: "ancestor", depth: 0)
        let primary = makeSegment(id: "primary", depth: 1)
        let other = makeSegment(id: "other", depth: 1)
        let service = ImmediateSunburstLayoutService(segments: [ancestor, primary, other])
        let model = SunburstChartModel(layoutService: service)
        _ = await model.loadLayout(makeRequest(layoutID: "layout"))

        var selection = NodeSelection()
        selection.replace(with: [other.nodeID!, "offscreen", primary.nodeID!], primary: primary.nodeID)
        let segments = model.selectionOverlaySegments(
            selection: selection, selectedAncestorIDs: [ancestor.nodeID!, primary.nodeID!]
        )
        #expect(segments.map(\.segment.id) == [ancestor.id, other.id, primary.id])
        #expect(segments.map(\.role) == [.ancestor, .selected, .selected])

        // A new member set under the same primary is a new overlay, not the memo of the old one.
        selection.add(ancestor.nodeID!)
        selection.add(primary.nodeID!)
        let grown = model.selectionOverlaySegments(
            selection: selection, selectedAncestorIDs: [ancestor.nodeID!, primary.nodeID!]
        )
        #expect(grown.map(\.segment.id) == [other.id, ancestor.id, primary.id])
        #expect(grown.allSatisfy { $0.role == .selected })
    }

    @Test func applyStyleRecolorsWithoutReLayoutAndKeepsHover() async throws {
        let file = makeTestFileNode(id: "/root/file.mov", name: "file.mov", size: 10)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let segment = makeSegment(id: "/root/file.mov")
        let service = CountingSunburstLayoutService(segments: [segment])
        let model = SunburstChartModel(layoutService: service)

        let didApplyLayout = await model.loadLayout(SunburstLayoutRequest(
            treeStore: store,
            rootID: root.id,
            depthLimit: 1,
            style: SunburstColorStyle(mode: .branch),
            freeSpaceBytes: nil,
            hiddenSpaceBytes: nil,
            expandedAggregateIDs: [],
            includeCloudOnly: false,
            layoutID: "layout"
        ))
        #expect(didApplyLayout)
        let versionAfterLoad = model.renderedLayoutVersion
        model.setHoveredSegmentID(segment.id)
        let branchFill = try #require(model.renderedSegments.first?.fillRGB)

        let catalog = FileKindCatalog.build(from: store, mode: .categories)
        model.applyStyle(SunburstColorStyle(mode: .kind, catalog: catalog), in: store)

        // Recolored in place: no second layout request, redrawn segments,
        // surviving hover, and a fill that reflects the new mode.
        #expect(await service.requestCount == 1)
        #expect(model.renderedLayoutVersion == versionAfterLoad + 1)
        #expect(model.hoveredSegmentID == segment.id)
        let kindFill = try #require(model.renderedSegments.first?.fillRGB)
        #expect(kindFill != branchFill)
    }
}

/// The fakes hand back segments; the model takes them as a chart without deep rings.
private protocol SegmentsLayouting: SunburstLayouting {
    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment]
}

extension SegmentsLayouting {
    func layout(for request: SunburstLayoutRequest) async throws -> SunburstChartLayout {
        SunburstChartLayout(segments: try await segments(for: request))
    }
}

private actor CountingSunburstLayoutService: SegmentsLayouting {
    private let renderedSegments: [SunburstSegment]
    private(set) var requestCount = 0

    init(segments: [SunburstSegment]) {
        renderedSegments = segments
    }

    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment] {
        requestCount += 1
        return renderedSegments
    }
}

private actor ImmediateSunburstLayoutService: SegmentsLayouting {
    private let renderedSegments: [SunburstSegment]

    init(segments: [SunburstSegment]) {
        renderedSegments = segments
    }

    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment] {
        renderedSegments
    }
}

private actor ControllableSunburstLayoutService: SegmentsLayouting {
    private struct RequestWaiter {
        let requestCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CancellationWaiter {
        let requestID: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let resumesOnCancellation: Bool
    private var issuedRequestCount = 0
    private var continuations: [Int: CheckedContinuation<[SunburstSegment], Error>] = [:]
    private var cancelledRequestIDs: Set<Int> = []
    private var waiters: [RequestWaiter] = []
    private var cancellationWaiters: [CancellationWaiter] = []

    init(resumesOnCancellation: Bool = false) {
        self.resumesOnCancellation = resumesOnCancellation
    }

    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment] {
        let requestID = issuedRequestCount
        issuedRequestCount += 1
        resumeSatisfiedWaiters()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledRequestIDs.contains(requestID) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[requestID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.handleCancellation(id: requestID)
            }
        }
    }

    func waitForIssuedRequestCount(_ requestCount: Int) async {
        guard issuedRequestCount < requestCount else { return }

        await withCheckedContinuation { continuation in
            waiters.append(RequestWaiter(requestCount: requestCount, continuation: continuation))
        }
    }

    func waitForCancelledRequest(id requestID: Int) async {
        guard !cancelledRequestIDs.contains(requestID) else { return }

        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CancellationWaiter(requestID: requestID, continuation: continuation))
        }
    }

    func completeRequest(id: Int, with segments: [SunburstSegment]) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: segments)
        return true
    }

    private func resumeSatisfiedWaiters() {
        var waiting: [RequestWaiter] = []
        for waiter in waiters {
            if issuedRequestCount >= waiter.requestCount {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }

    private func handleCancellation(id requestID: Int) {
        cancelledRequestIDs.insert(requestID)
        if resumesOnCancellation,
           let continuation = continuations.removeValue(forKey: requestID) {
            continuation.resume(throwing: CancellationError())
        }
        resumeCancellationWaiters()
    }

    private func resumeCancellationWaiters() {
        var waiting: [CancellationWaiter] = []
        for waiter in cancellationWaiters {
            if cancelledRequestIDs.contains(waiter.requestID) {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        cancellationWaiters = waiting
    }
}

private func makeRequest(layoutID: String) -> SunburstLayoutRequest {
    let root = makeTestDirectoryNode(id: "/root", name: "root", children: [])
    return SunburstLayoutRequest(
        treeStore: FileTreeStore(root: root),
        rootID: "/root",
        depthLimit: 1,
        style: SunburstColorStyle(),
        freeSpaceBytes: nil,
        hiddenSpaceBytes: nil,
        expandedAggregateIDs: [],
        includeCloudOnly: false,
        layoutID: layoutID
    )
}

@Suite struct SunburstCleanupOverlayTests {
    private func arc(_ id: String, _ start: Double, _ end: Double, ring: Int, aggregate: Bool = false) -> SunburstSegment {
        SunburstSegment(
            id: id, nodeID: aggregate ? nil : id, label: id,
            startAngle: start, endAngle: end,
            innerRadius: 0.2 + Double(ring) * 0.1, outerRadius: 0.3 + Double(ring) * 0.1,
            depth: ring,
            colorToken: SunburstColorToken(midpoint: 0.5, depth: ring, role: .normal),
            totalSize: 1, isAggregate: aggregate
        )
    }

    @Test func washCoversTheCollectedArcAndEverythingOutsideItsSpan() {
        let segments = [
            arc("/a", 0, 2, ring: 0), arc("/b", 2, 4, ring: 0),
            arc("/a/x", 0, 1, ring: 1), arc("/a/pool", 1, 2, ring: 1, aggregate: true),
            arc("/b/y", 2, 4, ring: 1),
        ]
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let overlay = SunburstCleanupOverlay(
            segments: segments, marks: { byID[$0] }, collected: ["/a"], moving: [], rootIsInside: false
        )
        #expect(overlay.collected.map(\.id) == ["/a"])
        #expect(Set(overlay.wash.map(\.id)) == ["/a", "/a/x", "/a/pool"])

        let moving = SunburstCleanupOverlay(
            segments: segments, marks: { byID[$0] }, collected: ["/a"], moving: ["/a"], rootIsInside: false
        )
        #expect(moving.collected.isEmpty)
        #expect(moving.moving.map(\.id) == ["/a"])

        let unrendered = SunburstCleanupOverlay(
            segments: segments, marks: { byID[$0] }, collected: ["/gone"], moving: [], rootIsInside: false
        )
        #expect(unrendered.isEmpty)

        let inside = SunburstCleanupOverlay(
            segments: segments, marks: { byID[$0] }, collected: ["/elsewhere"], moving: [], rootIsInside: true
        )
        #expect(inside.wash.count == segments.count)
        #expect(inside.collected.isEmpty)
    }
}

private func makeSegment(id: String, depth: Int = 0) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: id,
        label: id,
        startAngle: 0,
        endAngle: 1,
        innerRadius: 0,
        outerRadius: 1,
        depth: depth,
        colorToken: SunburstColorToken(midpoint: 0.5, depth: depth, role: .normal),
        totalSize: 1,
        isAggregate: false
    )
}

private actor FailingReplacementLayoutService: SegmentsLayouting {
    let segment: SunburstSegment
    init(segment: SunburstSegment) { self.segment = segment }
    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment] {
        if request.layoutID == "failed" { throw CocoaError(.fileReadUnknown) }
        return [segment]
    }
}
