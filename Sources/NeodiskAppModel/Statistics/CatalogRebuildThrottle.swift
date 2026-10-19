// Skips a stats-catalog rebuild while partials stream if the last was within ~10x its measured cost, so a big
// changing tree isn't rebuilt every partial. Callers always rebuild the complete snapshot.

import Foundation

package struct CatalogRebuildThrottle {
    private let baseInterval: Duration
    private var interval: Duration
    private var lastBuildTime: ContinuousClock.Instant?

    package init(baseInterval: Duration = .seconds(1.5)) {
        self.baseInterval = baseInterval
        self.interval = baseInterval
    }

    /// Whether a rebuild should be skipped right now — only ever true for a
    /// partial snapshot within the current interval of the last build.
    package func shouldSkip() -> Bool {
        guard let lastBuildTime else { return false }
        return ContinuousClock.now - lastBuildTime < interval
    }

    /// Marks a rebuild as starting now.
    package mutating func noteBuildStarted() {
        lastBuildTime = ContinuousClock.now
    }

    /// Feeds back the measured build cost; the next interval is at least the
    /// base and never more than ~10% of the time spent building.
    package mutating func noteBuildDuration(_ duration: Duration) {
        interval = max(baseInterval, duration * 10)
    }

    /// Resets to the initial state — a new scan or snapshot took the screen.
    package mutating func reset() {
        interval = baseInterval
        lastBuildTime = nil
    }
}
