// What the treemap and sunburst presenters need from whoever shows them: the window canvas, or a headless run
// that renders one frame to a PNG with the same code.

import Foundation
import NeodiskAppModel
import WinSDK

@MainActor
protocol CanvasHost: AnyObject {
    var model: VizCanvasModel { get }
    /// In DIPs.
    var viewSize: CGSize { get }
    /// Device pixels per DIP.
    var scale: Double { get }
    var device: D2DCanvas? { get }
    var mailbox: CanvasMailbox { get }
    var stats: CanvasStats { get }
    /// False while another view is on screen; it renders when shown again.
    func isShowing(_ presenter: AnyObject) -> Bool
    func invalidate()
    /// Rasterizes off the main thread; a headless host runs the job inline.
    func runInBackground(_ job: @escaping @Sendable () -> Void)
    func beep()
    func screenPoint(for viewPoint: CGPoint) -> POINT
    var hasFocus: Bool { get }
    var showsFocusRing: Bool { get }
}

/// Results from background renders, handed to the canvas's thread through a posted window message so the canvas
/// works whatever drains the main queue.
final class CanvasMailbox: @unchecked Sendable {
    static let message = UINT(WM_APP) + 0x2D1
    private let lock = NSLock()
    private var items: [@MainActor @Sendable () -> Void] = []
    private var window: UInt = 0
    /// Headless: run deliveries in place (the caller is on the main thread).
    let isInline: Bool

    init(isInline: Bool = false) {
        self.isInline = isInline
    }

    func attach(_ hwnd: HWND?) {
        lock.lock()
        window = hwnd.map { UInt(bitPattern: $0) } ?? 0
        lock.unlock()
    }

    func post(_ item: @escaping @MainActor @Sendable () -> Void) {
        if isInline {
            MainActor.assumeIsolated { item() }
            return
        }
        lock.lock()
        items.append(item)
        let target = window
        let isFirst = items.count == 1
        lock.unlock()
        if isFirst, target != 0, let hwnd = HWND(bitPattern: target) {
            _ = PostMessageW(hwnd, Self.message, 0, 0)
        }
    }

    @MainActor
    func drain() {
        lock.lock()
        let pending = items
        items.removeAll()
        lock.unlock()
        for item in pending { item() }
    }
}

/// Frame and raster timings, for the benchmark and NEODISK_CANVAS_STATS.
final class CanvasStats: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]

    func record(_ name: String, ms: Double) {
        lock.lock()
        samples[name, default: []].append(ms)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func values(_ name: String) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return samples[name] ?? []
    }

    func summary(_ name: String) -> String {
        let values = values(name).sorted()
        guard !values.isEmpty else { return "\(name): no samples" }
        let average = values.reduce(0, +) / Double(values.count)
        let p95 = values[min(values.count - 1, Int((Double(values.count) * 0.95).rounded(.up)) - 1)]
        return String(
            format: "%@: n=%d avg=%.2f ms p95=%.2f ms max=%.2f ms",
            name, values.count, average, p95, values.last ?? 0
        )
    }
}

enum Clock {
    nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

/// Mouse-wheel drilling: one notch (or a touchpad's worth of small deltas) is one level, and the latch holds until
/// the wheel rests so one flick doesn't fall through several folders.
struct WheelDrillLatch {
    private var accumulated = 0.0
    private var latchedUntil: ContinuousClock.Instant?

    enum Direction { case drillIn, drillOut }

    /// `notches` is positive away from the user (zoom in).
    mutating func feed(notches: Double) -> Direction? {
        let now = ContinuousClock.now
        if let latchedUntil, now < latchedUntil {
            self.latchedUntil = now + .milliseconds(220)
            return nil
        }
        latchedUntil = nil
        if (accumulated > 0) != (notches > 0) { accumulated = 0 }
        accumulated += notches
        guard abs(accumulated) >= 1 else { return nil }
        let direction: Direction = accumulated > 0 ? .drillIn : .drillOut
        accumulated = 0
        latchedUntil = now + .milliseconds(220)
        return direction
    }
}

/// Windows' "Animation effects" setting (off under reduced motion).
@MainActor
var systemAnimationsEnabled: Bool {
    if ProcessInfo.processInfo.environment["NEODISK_CANVAS_ANIMATIONS"] == "0" { return false }
    var enabled: WindowsBool = true
    guard SystemParametersInfoW(UINT(SPI_GETCLIENTAREAANIMATION), 0, &enabled, 0) else { return true }
    return enabled.boolValue
}

extension AppStrings {
    static func text(_ key: String) -> String {
        localized(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key, comment: ""), arguments: arguments)
    }
}
