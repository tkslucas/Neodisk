//
//  IncrementalRescanCoordinator.swift
//  Neodisk
//

import Foundation

/// Order-preserving bounded async map. Incremental subtree scans use this
/// instead of launching an unbounded task per FSEvents root.
nonisolated enum BoundedAsyncMap {
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let workerLimit = min(max(1, limit), inputs.count)
        var outputs = Array<Output?>(repeating: nil, count: inputs.count)

        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var nextInputIndex = 0
            func submitNext() {
                guard nextInputIndex < inputs.count else { return }
                let index = nextInputIndex
                let input = inputs[index]
                nextInputIndex += 1
                group.addTask {
                    (index, try await operation(input))
                }
            }

            for _ in 0..<workerLimit {
                submitNext()
            }
            while let (index, output) = try await group.next() {
                outputs[index] = output
                submitNext()
            }
        }

        return outputs.compactMap { $0 }
    }
}

/// Thread-safe aggregation of cumulative progress from independent subtree
/// streams. Results are summed by stable input index, so completion order does
/// not affect counters or the final splice ordering.
nonisolated final class IncrementalRescanProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private let base: ScanMetrics
    private let retainedFraction: Double
    private let progressCeiling: Double
    private var latestByIndex: [ScanMetrics?]

    init(
        base: ScanMetrics,
        subtreeCount: Int,
        retainedFraction: Double,
        progressCeiling: Double
    ) {
        self.base = base
        self.retainedFraction = retainedFraction
        self.progressCeiling = progressCeiling
        self.latestByIndex = Array(repeating: nil, count: max(0, subtreeCount))
    }

    func update(index: Int, metrics: ScanMetrics) -> ScanMetrics {
        lock.lock()
        defer { lock.unlock() }
        guard latestByIndex.indices.contains(index) else { return base }
        latestByIndex[index] = metrics

        var combined = base
        var progressTotal = 0.0
        for latest in latestByIndex.compactMap({ $0 }) {
            combined.filesVisited += latest.filesVisited
            combined.directoriesVisited += latest.directoriesVisited
            combined.bytesDiscovered = combined.bytesDiscovered.addingClamped(latest.bytesDiscovered)
            progressTotal += min(max(latest.progressFraction, 0), 1)
        }
        combined.currentPath = metrics.currentPath
        let rescanFraction = progressTotal / Double(max(latestByIndex.count, 1))
        combined.progressFraction = min(
            retainedFraction + rescanFraction * (progressCeiling - retainedFraction),
            progressCeiling
        )
        return combined
    }
}
