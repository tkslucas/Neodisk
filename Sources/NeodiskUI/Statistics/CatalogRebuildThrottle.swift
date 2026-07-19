//
//  CatalogRebuildThrottle.swift
//  Neodisk
//
//  Adaptive throttle for the O(nodes) stats-catalog rebuild while a scan
//  streams partials, shared by the Kind and Age catalogs: skip a rebuild if
//  the last one was under an interval ago, where the interval grows to ~10×
//  the measured build cost — the same cost × N adaptation as partial-tree
//  emission — so a fast-changing big tree isn't rebuilt on every partial. The
//  final complete snapshot always rebuilds (callers gate on `isComplete`
//  before consulting `shouldSkip`).
//

import Foundation

struct CatalogRebuildThrottle {
    private let baseInterval: Duration
    private var interval: Duration
    private var lastBuildTime: ContinuousClock.Instant?

    init(baseInterval: Duration = .seconds(1.5)) {
        self.baseInterval = baseInterval
        self.interval = baseInterval
    }

    /// Whether a rebuild should be skipped right now — only ever true for a
    /// partial snapshot within the current interval of the last build.
    func shouldSkip() -> Bool {
        guard let lastBuildTime else { return false }
        return ContinuousClock.now - lastBuildTime < interval
    }

    /// Marks a rebuild as starting now.
    mutating func noteBuildStarted() {
        lastBuildTime = ContinuousClock.now
    }

    /// Feeds back the measured build cost; the next interval is at least the
    /// base and never more than ~10% of the time spent building.
    mutating func noteBuildDuration(_ duration: Duration) {
        interval = max(baseInterval, duration * 10)
    }

    /// Resets to the initial state — a new scan or snapshot took the screen.
    mutating func reset() {
        interval = baseInterval
        lastBuildTime = nil
    }
}
