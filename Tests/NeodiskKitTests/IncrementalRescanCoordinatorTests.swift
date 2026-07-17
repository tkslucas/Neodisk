import Foundation
import Testing
@testable import NeodiskKit

@Suite(.serialized) struct IncrementalRescanCoordinatorTests {
    @Test func boundedMapLimitsConcurrencyAndPreservesInputOrder() async throws {
        let tracker = ActiveTaskTracker()
        let outputs = try await BoundedAsyncMap.run(Array(0..<12), limit: 3) { value in
            await tracker.enter()
            try await Task.sleep(for: .milliseconds(5))
            await tracker.leave()
            return value * 2
        }

        #expect(outputs == Array(0..<12).map { $0 * 2 })
        #expect(await tracker.maximumActive == 3)
    }

    @Test func aggregatedProgressIsIndependentOfSubtreeCompletionOrder() {
        var base = ScanMetrics()
        base.filesVisited = 10
        base.bytesDiscovered = 100

        var first = ScanMetrics()
        first.filesVisited = 3
        first.bytesDiscovered = 30
        first.progressFraction = 1
        first.currentPath = "/a"

        var second = ScanMetrics()
        second.filesVisited = 7
        second.bytesDiscovered = 70
        second.progressFraction = 0.5
        second.currentPath = "/b"

        let forward = IncrementalRescanProgressAggregator(
            base: base,
            subtreeCount: 2,
            retainedFraction: 0.25,
            progressCeiling: 0.95
        )
        _ = forward.update(index: 0, metrics: first)
        let forwardResult = forward.update(index: 1, metrics: second)

        let reverse = IncrementalRescanProgressAggregator(
            base: base,
            subtreeCount: 2,
            retainedFraction: 0.25,
            progressCeiling: 0.95
        )
        _ = reverse.update(index: 1, metrics: second)
        let reverseResult = reverse.update(index: 0, metrics: first)

        #expect(forwardResult.filesVisited == reverseResult.filesVisited)
        #expect(forwardResult.bytesDiscovered == reverseResult.bytesDiscovered)
        #expect(forwardResult.progressFraction == reverseResult.progressFraction)
        #expect(forwardResult.filesVisited == 20)
        #expect(forwardResult.bytesDiscovered == 200)
    }
}

private actor ActiveTaskTracker {
    private var active = 0
    private(set) var maximumActive = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
    }
}
