//
//  CloudScanService.swift
//  Neodisk
//
//  Drives a CloudProvider enumeration and emits the same ScanProgressEvent
//  stream as the local ScanEngine, so ScanCoordinator and everything
//  downstream (partial rendering, snapshot cache, diffing) work unchanged.
//

import Foundation
import NeodiskKit

public final class CloudScanService: Sendable {
    private let providers: [String: any CloudProvider]
    /// Minimum spacing between partial-tree emissions. Rebuilding the tree
    /// is O(entries), so partials are paced by time, not page count.
    private let partialInterval: Duration

    public init(providers: [any CloudProvider], partialInterval: Duration = .milliseconds(1500)) {
        self.providers = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.providerID, $0) }
        )
        self.partialInterval = partialInterval
    }

    public func provider(forID providerID: String) -> (any CloudProvider)? {
        providers[providerID]
    }

    /// Mirrors ScanEngine.scan: `.progress`/`.partial` while enumerating,
    /// one `.finished` that must never be dropped, errors via the stream.
    public func scan(target: ScanTarget) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                do {
                    try await self.runScan(target: target, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runScan(
        target: ScanTarget,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation
    ) async throws {
        guard let parsed = CloudTargetID.parse(target.id),
              let provider = providers[parsed.providerID] else {
            throw CloudScanError.invalidTarget(target.id)
        }
        guard let account = try provider.restoreAccounts().first(where: {
            $0.accountID == parsed.accountID
        }) else {
            throw CloudScanError.accountNotConnected(target.displayName)
        }

        let startedAt = Date()
        let quota = try await provider.quota(for: account)
        let rootFolderID = try await provider.rootFolderID(for: account)
        var builder = CloudTreeBuilder(
            target: target,
            providerID: provider.providerID,
            rootFolderID: rootFolderID
        )

        var metrics = ScanMetrics()
        metrics.currentPath = target.displayName
        metrics.recalculateProgress()
        continuation.yield(.progress(metrics))

        let clock = ContinuousClock()
        var lastPartialAt: ContinuousClock.Instant?

        for try await page in provider.listAllFiles(for: account) {
            try Task.checkCancellation()
            builder.add(page)

            metrics.filesVisited = builder.fileCount
            metrics.directoriesVisited = builder.folderCount
            metrics.bytesDiscovered = builder.allocatedBytesDiscovered
            metrics.currentPath = builder.latestEntryName ?? target.displayName
            metrics.progressFraction = Self.progressFraction(
                previous: metrics.progressFraction,
                bytesDiscovered: builder.allocatedBytesDiscovered,
                quotaUsedBytes: quota.usedBytes
            )
            continuation.yield(.progress(metrics))

            let now = clock.now
            if lastPartialAt.map({ now - $0 >= partialInterval }) ?? true {
                lastPartialAt = now
                continuation.yield(.partial(builder.buildTree(isComplete: false, quota: nil)))
            }
        }
        try Task.checkCancellation()

        let tree = builder.buildTree(isComplete: true, quota: quota)
        let snapshot = ScanSnapshot(
            target: target,
            treeStore: tree,
            startedAt: startedAt,
            finishedAt: Date(),
            scanWarnings: [],
            aggregateStats: tree.aggregateStats,
            isComplete: true,
            scanOptions: nil,
            source: .live
        )
        metrics.recalculateProgress(isComplete: true)
        continuation.yield(.progress(metrics))
        continuation.yield(.finished(snapshot))
    }

    /// Monotonic byte-ratio progress against the account's quota usage,
    /// capped below 1 until the final snapshot lands. The local engine's
    /// weight model needs traversal internals a remote listing doesn't have.
    static func progressFraction(
        previous: Double,
        bytesDiscovered: Int64,
        quotaUsedBytes: Int64
    ) -> Double {
        guard quotaUsedBytes > 0 else { return max(previous, 0.01) }
        let fraction = min(Double(bytesDiscovered) / Double(quotaUsedBytes), 1) * 0.95
        return max(previous, max(fraction, 0.01))
    }
}
