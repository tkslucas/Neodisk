import Darwin
import Foundation
import NeodiskKit

/// With `NEODISK_SCAN_PROFILE=1`, pings the main queue every 16 ms and records waits and stalls over 50 ms.
/// While a ping is late it samples the main stack every 5 ms, so a stall names the code that caused it.
enum MainThreadMonitor {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stackCounts: [[UInt]: Int] = [:]
    nonisolated(unsafe) private static var monitorStart: UInt64 = 0
    /// NEODISK_STALL_LOG_MS (default 100): stalls longer than this get their own line.
    private static let stallLogThreshold: UInt64 = 1_000_000 * (ProcessInfo.processInfo.environment["NEODISK_STALL_LOG_MS"]
        .flatMap(UInt64.init) ?? 100)
    /// Milliseconds since the monitor started: the clock its stall lines use.
    static var elapsedMs: UInt64 { (ScanProfile.now() &- monitorStart) / 1_000_000 }

    static func startIfProfiling() {
        guard ScanProfile.isEnabled, !started else { return }
        started = true
        // Started from FeltTiming on the main thread.
        guard Thread.isMainThread else { started = false; return }
        mainThread = mach_thread_self()
        monitorStart = ScanProfile.now()
        let thread = Thread {
            while true {
                let since = ScanProfile.now()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    ScanProfile.addNamed("app.mainLatency", since: since)
                    if ScanProfile.now() &- since > 50_000_000 {
                        ScanProfile.addNamed("app.mainStall", since: since)
                    }
                    answered.signal()
                }
                // Late past 20 ms: sample what the main thread is doing.
                if answered.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
                    var stall: [[UInt]] = []
                    while answered.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
                        if let frames = sampleMainThread() { stall.append(frames) }
                    }
                    let elapsed = ScanProfile.now() &- since
                    if elapsed > stallLogThreshold { logStall(stall, at: since &- monitorStart, lasting: elapsed) }
                }
                Thread.sleep(forTimeInterval: 0.016)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "com.neodisk.main-thread-monitor"
        thread.start()
    }

    /// One line per stall over the threshold, when it began (ms since the monitor started), and the Neodisk frames
    /// (marked `*`) seen in most of its samples, innermost first: which interaction stalled, and in what code.
    private static func logStall(_ samples: [[UInt]], at offset: UInt64, lasting elapsed: UInt64) {
        var inclusive: [String: Int] = [:]
        for frames in samples {
            for symbol in Set(frames.map(symbol(for:))) where symbol.hasPrefix("*") {
                inclusive[symbol, default: 0] += 1
            }
        }
        let own = inclusive.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.value)/\(samples.count) \($0.key)" }
        // Leaf-side frames shared by most samples, to name framework work (layout, display) the own frames miss.
        var leafCounts: [String: Int] = [:]
        for frames in samples {
            for symbol in Set(frames.prefix(12).map(symbol(for:))) { leafCounts[symbol, default: 0] += 1 }
        }
        let leaves = leafCounts.filter { $0.key != "?" }.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.value) \($0.key.prefix(70))" }
        ScanTiming.note("mainStall atMs=\(offset / 1_000_000) ms=\(elapsed / 1_000_000) | " + own.joined(separator: " | ")
            + " || leaf: " + leaves.joined(separator: " | "))
    }

    /// Suspends the main thread, walks its frame-pointer chain, resumes it.
    @discardableResult
    private static func sampleMainThread() -> [UInt]? {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return nil }
        var frames: [UInt] = []
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            frames.append(UInt(state.__pc) & 0x0000_FFFF_FFFF_FFFF)
            frames.append(UInt(state.__lr) & 0x0000_FFFF_FFFF_FFFF)
            var framePointer = UInt(state.__fp)
            // Each frame record is [previous fp, return address].
            for _ in 0..<64 {
                guard framePointer != 0, framePointer & 0x7 == 0,
                      let record = UnsafePointer<UInt>(bitPattern: framePointer) else { break }
                let next = record[0]
                let returnAddress = record[1] & 0x0000_FFFF_FFFF_FFFF
                guard returnAddress != 0 else { break }
                frames.append(returnAddress)
                guard next > framePointer else { break }
                framePointer = next
            }
        }
        #endif
        thread_resume(mainThread)
        guard !frames.isEmpty else { return nil }
        lock.lock()
        stackCounts[frames, default: 0] += 1
        lock.unlock()
        return frames
    }

    /// Prints the stall stacks sampled most often, grouped by their innermost
    /// frames in Neodisk's own code (marked `*`), and clears them.
    static func emitStallStacks() {
        guard ScanProfile.isEnabled else { return }
        lock.lock()
        let counts = stackCounts
        stackCounts = [:]
        lock.unlock()
        // Inclusive counts per frame, as in a call tree. Frames in nearly every sample are the run loop and
        // say nothing.
        var inclusive: [String: Int] = [:]
        var total = 0
        for (frames, count) in counts {
            total += count
            for symbol in Set(frames.map(symbol(for:))) {
                inclusive[symbol, default: 0] += count
            }
        }
        guard total > 0 else { return }
        let telling = inclusive.filter { $0.value * 100 < total * 90 && $0.key != "?" }
        for (symbol, count) in telling.sorted(by: { $0.value > $1.value }).prefix(16) {
            ScanTiming.note("mainStallFrame samples=\(count)/\(total) \(symbol)")
        }
    }

    private static let ownImage: String = {
        var info = Dl_info()
        dladdr(#dsohandle, &info)
        return info.dli_fname.map { String(cString: $0) } ?? ""
    }()

    private static func symbol(for address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname else {
            return "?"
        }
        let isOwn = info.dli_fname.map { String(cString: $0) } == ownImage
        return (isOwn ? "*" : "") + demangle(String(cString: name))
    }

    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangler: Demangler? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangler.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard let demangler, let result = name.withCString({ demangler($0, strlen($0), nil, nil, 0) }) else {
            return name
        }
        defer { free(result) }
        return String(String(cString: result).prefix(110))
    }
}
