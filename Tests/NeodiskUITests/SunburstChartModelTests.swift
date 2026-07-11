//
//  SunburstChartModelTests.swift
//  Neodisk
//
//  Ported from Radix: generation-guarded layout loads (stale results
//  dropped, older work cancelled), hover clearing, and selection overlay
//  ordering.
//

import Combine
import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

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

    @Test func selectionOverlaySegmentsIncludeAncestorsAndSelectedLast() async {
        let ancestor = makeSegment(id: "ancestor", depth: 0)
        let selected = makeSegment(id: "selected", depth: 1)
        let sibling = makeSegment(id: "sibling", depth: 1)
        let service = ImmediateSunburstLayoutService(segments: [ancestor, selected, sibling])
        let model = SunburstChartModel(layoutService: service)

        let didApplyLayout = await model.loadLayout(makeRequest(layoutID: "layout"))

        #expect(didApplyLayout)
        let overlaySegments = model.selectionOverlaySegments(
            selectedNodeID: selected.nodeID,
            selectedAncestorIDs: Set([ancestor.nodeID!, selected.nodeID!, "missing"])
        )

        #expect(overlaySegments.map(\.segment.id) == [ancestor.id, selected.id])
        #expect(overlaySegments.map(\.role) == [.ancestor, .selected])
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

private actor CountingSunburstLayoutService: SunburstLayouting {
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

private actor ImmediateSunburstLayoutService: SunburstLayouting {
    private let renderedSegments: [SunburstSegment]

    init(segments: [SunburstSegment]) {
        renderedSegments = segments
    }

    func segments(for request: SunburstLayoutRequest) async throws -> [SunburstSegment] {
        renderedSegments
    }
}

private actor ControllableSunburstLayoutService: SunburstLayouting {
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
        layoutID: layoutID
    )
}

private func makeSegment(id: String, depth: Int = 0) -> SunburstSegment {
    SunburstSegment(
        id: id,
        nodeID: id,
        label: id,
        startAngle: .radians(0),
        endAngle: .radians(1),
        innerRadius: 0,
        outerRadius: 1,
        depth: depth,
        colorToken: .single(id: id, depth: depth),
        totalSize: 1,
        isAggregate: false
    )
}
