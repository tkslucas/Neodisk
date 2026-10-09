#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Exact per-scan counters and a throughput timeline for the scan hot paths,
/// for finding where a scan's wall time goes. `NEODISK_SCAN_PROFILE=1` turns
/// it on; off, every call is one load of a static `Bool`.
///
/// Each counter keeps a call count, total and max nanoseconds. At scan end
/// `emit()` prints one `NEODISK_SCAN_TIMING phase=profile.<name> ms=<total>
/// count=<n> maxMs=<max>` line per counter that ran (the timing-line
/// contract), and while the scan runs a sampler prints `note timeline` lines
/// every 500 ms with the deltas, so stalls and slow tails show up in time.
package nonisolated enum ScanProfile {
    package static let isEnabled = ProcessInfo.processInfo.environment["NEODISK_SCAN_PROFILE"] == "1"

    enum Counter: Int, CaseIterable {
        /// Coordinator loop time not spent awaiting a finished task.
        case coordinatorBusy
        /// Coordinator time awaiting `group.next()`.
        case coordinatorWait
        /// Directories handed to workers (count only).
        case directoriesDispatched
        /// Executor: queued until a worker queue starts the read.
        case ioQueueWait
        /// One directory's open + getattrlistbulk loop + close, entries parsed in Swift included.
        case ioRead
        /// The `open` of a traversal directory.
        case ioOpen
        /// `getattrlistbulk` calls returning entries.
        case ioBulk
        /// The final `getattrlistbulk` that returns 0.
        case ioBulkEnd
        /// Entries returned by traversal reads (count only).
        case entries
        /// Worker-side leaf-record batch building.
        case leafBatch
        /// Coordinator handling of a finished directory.
        case handleDirectory
        /// Atomic-summary probe/summary tasks.
        case summaryTask
        /// Package summary tasks.
        case packageTask
        /// Partial-tree builds for live display.
        case partialBuild
        /// Partial build: walking the shallow keys into records.
        case partialWalk
        /// Partial build: the store built from those records.
        case partialStore
        /// Records in each partial tree (count only).
        case partialNodes
        /// Clone private-size reads during traversal (`getattrlistat`), only
        /// with NEODISK_SCAN_VERIFY_CLONES=1.
        case clonePrivateSize
        /// Verified clone members whose private size was not 0 (count only).
        case clonePrivateSizeMismatch
        /// Assembly clone dedup: grouping members into families.
        case cloneGroup
        /// Assembly clone dedup: ordering each family's members.
        case cloneOrder
        /// Assembly clone dedup: charging members and rebuilding ancestors.
        case cloneApply
        /// Assembly clone dedup: the ancestor rebuild after charging.
        case cloneRebuild
        /// Progress events published.
        case progressPublish
    }

    private static let count = Counter.allCases.count
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = [UInt64](repeating: 0, count: count)
    nonisolated(unsafe) private static var nanos = [UInt64](repeating: 0, count: count)
    nonisolated(unsafe) private static var maxNanos = [UInt64](repeating: 0, count: count)
    nonisolated(unsafe) private static var timeline: DispatchSourceTimer?
    nonisolated(unsafe) private static var start: UInt64 = 0
    nonisolated(unsafe) private static var inFlight: [Int: (counter: Counter, detail: String, since: UInt64)] = [:]
    nonisolated(unsafe) private static var nextToken = 1

    /// Registers work that has started, so the timeline can show what is
    /// running now and name anything stuck. Returns a token for `finish`.
    static func started(_ counter: Counter, _ detail: @autoclosure () -> String = "") -> Int {
        guard isEnabled else { return 0 }
        let entry = (counter: counter, detail: detail(), since: DispatchTime.now().uptimeNanoseconds)
        lock.lock()
        let token = nextToken
        nextToken += 1
        inFlight[token] = entry
        lock.unlock()
        return token
    }

    /// Ends work registered with `started` and adds its span to the counter.
    static func finish(_ token: Int, count: Int = 1) {
        guard isEnabled, token != 0 else { return }
        lock.lock()
        let entry = inFlight.removeValue(forKey: token)
        lock.unlock()
        if let entry {
            add(entry.counter, count: count, nanoseconds: DispatchTime.now().uptimeNanoseconds &- entry.since)
        }
    }

    private static func inFlightReport() -> String {
        lock.lock()
        let entries = Array(inFlight.values)
        lock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        var byCounter: [Counter: Int] = [:]
        for entry in entries { byCounter[entry.counter, default: 0] += 1 }
        var report = " inFlight=" + byCounter.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let stuck = entries.filter { now &- $0.since > 1_000_000_000 }
            .sorted { $0.since < $1.since }
            .prefix(3)
        for entry in stuck {
            report += " stuck=\(entry.counter):\((now &- entry.since) / 1_000_000)ms:\(entry.detail)"
        }
        return report
    }

    @inline(__always)
    package static func now() -> UInt64 {
        guard isEnabled else { return 0 }
        return DispatchTime.now().uptimeNanoseconds
    }

    /// Adds a span that started at `since` (from `now()`).
    @inline(__always)
    static func end(_ counter: Counter, since: UInt64, count: Int = 1) {
        guard isEnabled else { return }
        add(counter, count: count, nanoseconds: DispatchTime.now().uptimeNanoseconds &- since)
    }

    static func add(_ counter: Counter, count: Int = 1, nanoseconds: UInt64 = 0) {
        guard isEnabled else { return }
        let index = counter.rawValue
        lock.lock()
        calls[index] &+= UInt64(count)
        nanos[index] &+= nanoseconds
        if nanoseconds > maxNanos[index] { maxNanos[index] = nanoseconds }
        lock.unlock()
    }

    @inline(__always)
    static func measure<T>(_ counter: Counter, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let since = DispatchTime.now().uptimeNanoseconds
        defer { end(counter, since: since) }
        return try body()
    }

    nonisolated(unsafe) private static var named: [String: (calls: UInt64, nanos: UInt64, max: UInt64)] = [:]

    /// A span outside the engine's fixed counters (the apps' render and
    /// display steps), by name. Kept until `emitNamed`, across scans.
    package static func addNamed(_ name: String, since: UInt64, count: Int = 1) {
        guard isEnabled else { return }
        let nanoseconds = DispatchTime.now().uptimeNanoseconds &- since
        lock.lock()
        var entry = named[name] ?? (0, 0, 0)
        entry.calls &+= UInt64(count)
        entry.nanos &+= nanoseconds
        entry.max = Swift.max(entry.max, nanoseconds)
        named[name] = entry
        lock.unlock()
    }

    /// Prints and clears the named spans.
    package static func emitNamed() {
        guard isEnabled else { return }
        lock.lock()
        let entries = named
        named = [:]
        lock.unlock()
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            ScanTiming.record(
                "profile.\(name)",
                .nanoseconds(Int64(entry.nanos)),
                detail: "count=\(entry.calls) maxMs=" + String(format: "%.2f", Double(entry.max) / 1e6)
            )
        }
    }

    /// Prints a breakdown of one directory read that took over 500 ms.
    static func noteSlowRead(
        path: @autoclosure () -> String,
        since: UInt64,
        syscallNanoseconds: UInt64,
        parseNanoseconds: UInt64,
        entries: Int
    ) {
        guard isEnabled else { return }
        let total = DispatchTime.now().uptimeNanoseconds &- since
        guard total > 500_000_000 else { return }
        ScanTiming.note(
            "slowRead ms=\(total / 1_000_000) syscallMs=\(syscallNanoseconds / 1_000_000)"
            + " parseMs=\(parseNanoseconds / 1_000_000) entries=\(entries) path=\(path())"
        )
    }

    private static func snapshot() -> (calls: [UInt64], nanos: [UInt64], max: [UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        return (calls, nanos, maxNanos)
    }

    /// Zeroes the counters and starts the timeline sampler.
    static func begin() {
        guard isEnabled else { return }
        lock.lock()
        inFlight = [:]
        calls = [UInt64](repeating: 0, count: count)
        nanos = [UInt64](repeating: 0, count: count)
        maxNanos = [UInt64](repeating: 0, count: count)
        start = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        timeline?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var previous = snapshot()
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler {
            let current = snapshot()
            func delta(_ counter: Counter) -> UInt64 {
                current.calls[counter.rawValue] &- previous.calls[counter.rawValue]
            }
            func busy(_ counter: Counter) -> Int {
                // Thread-milliseconds spent in the span during this window.
                Int((current.nanos[counter.rawValue] &- previous.nanos[counter.rawValue]) / 1_000_000)
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            ScanTiming.note(
                "timeline t=\(elapsed) dirs=\(delta(.ioRead)) entries=\(delta(.entries))"
                + " ioMs=\(busy(.ioRead)) bulkMs=\(busy(.ioBulk) + busy(.ioBulkEnd)) openMs=\(busy(.ioOpen))"
                + " queueWaitMs=\(busy(.ioQueueWait)) coordBusyMs=\(busy(.coordinatorBusy))"
                + " coordWaitMs=\(busy(.coordinatorWait)) partials=\(delta(.partialBuild))"
                + " partialMs=\(busy(.partialBuild)) clone=\(delta(.clonePrivateSize))"
                + " cloneMs=\(busy(.clonePrivateSize))"
                + " summaries=\(delta(.summaryTask)) summaryMs=\(busy(.summaryTask))"
                + inFlightReport()
            )
            previous = current
        }
        timeline = timer
        timer.resume()
    }

    /// Stops the sampler and prints the totals.
    static func emit() {
        guard isEnabled else { return }
        timeline?.cancel()
        timeline = nil
        let totals = snapshot()
        for counter in Counter.allCases {
            let index = counter.rawValue
            guard totals.calls[index] > 0 else { continue }
            ScanTiming.record(
                "profile.\(counter)",
                .nanoseconds(Int64(totals.nanos[index])),
                detail: "count=\(totals.calls[index]) maxMs="
                    + String(format: "%.2f", Double(totals.max[index]) / 1e6)
            )
        }
    }
}
