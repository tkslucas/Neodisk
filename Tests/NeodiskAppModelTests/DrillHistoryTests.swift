import Testing
@testable import NeodiskAppModel

/// Back/forward over drill roots: browser semantics, stale entries skipped,
/// bounded growth.
struct DrillHistoryTests {
    @Test func backAndForwardWalkTheRecordedRoots() {
        var history = DrillHistory()
        #expect(!history.canGoBack && !history.canGoForward)

        history.recordLeaving("/r")        // /r → /r/a
        history.recordLeaving("/r/a")      // /r/a → /r/a/b
        #expect(history.goBack(from: "/r/a/b") { _ in true } == "/r/a")
        #expect(history.goBack(from: "/r/a") { _ in true } == "/r")
        #expect(!history.canGoBack)
        #expect(history.goBack(from: "/r") { _ in true } == nil)

        #expect(history.goForward(from: "/r") { _ in true } == "/r/a")
        #expect(history.goForward(from: "/r/a") { _ in true } == "/r/a/b")
        #expect(!history.canGoForward)
    }

    @Test func aNewDrillDropsTheForwardTrail() {
        var history = DrillHistory()
        history.recordLeaving("/r")
        #expect(history.goBack(from: "/r/a") { _ in true } == "/r")
        #expect(history.canGoForward)

        history.recordLeaving("/r")        // drilled somewhere else instead
        #expect(!history.canGoForward)
        #expect(history.canGoBack)
    }

    @Test func entriesThatNoLongerExistOrMatchTheCurrentRootAreSkipped() {
        var history = DrillHistory()
        history.recordLeaving("/r")
        history.recordLeaving("/r/gone")
        history.recordLeaving("/r/a")
        // From /r/a: the newest entry is the current root itself, the next
        // was removed by a rescan; both are dropped on the way to /r.
        #expect(history.goBack(from: "/r/a") { $0 != "/r/gone" } == "/r")
        #expect(!history.canGoBack)
        #expect(history.goForward(from: "/r") { _ in true } == "/r/a")
    }

    @Test func historyIsBounded() {
        var history = DrillHistory()
        for index in 0..<(DrillHistory.limit + 10) {
            history.recordLeaving("/r/\(index)")
        }
        var steps = 0
        var current = "/r/end"
        while let previous = history.goBack(from: current, isValid: { _ in true }) {
            current = previous
            steps += 1
        }
        #expect(steps == DrillHistory.limit)
        #expect(current == "/r/10")        // the oldest ten were dropped
    }
}
