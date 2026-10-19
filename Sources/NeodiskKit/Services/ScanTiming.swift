#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The measurement harness parses these `NEODISK_SCAN_TIMING` lines, so the format is a contract. Phases are
/// coarse, never per-entry, so timing can't skew what it measures. Public so the UI's `app.*` marks share it.
public nonisolated enum ScanTiming {
    public static let isEnabled = ProcessInfo.processInfo.environment["NEODISK_SCAN_TIMING"] == "1"
        || ProcessInfo.processInfo.environment["NEODISK_SCAN_PROFILE"] == "1"

    /// Held from a phase's start so the emitted line carries CPU spent across the interval, not just wall time.
    public struct CPUSnapshot: Sendable {
        let user: Double
        let system: Double
    }

    public static func cpuSnapshot() -> CPUSnapshot {
        let (user, system) = processCPUMilliseconds()
        return CPUSnapshot(user: user, system: system)
    }

    /// One-off context line (worker limits, derating events) — same prefix,
    /// no ms field, ignored by the stats parser.
    public static func note(_ text: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data(("NEODISK_SCAN_TIMING note " + text + "\n").utf8))
    }

    public static func record(_ phase: String, _ duration: Duration, detail: String = "") {
        guard isEnabled else { return }
        let milliseconds = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        var line = "NEODISK_SCAN_TIMING phase=\(phase) ms=\(String(format: "%.1f", milliseconds))"
        if !detail.isEmpty {
            line += " " + detail
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Same detail fields as the engine's `measure`, so both parse identically. Nil omits the CPU fields.
    public static func record(
        _ phase: String,
        _ duration: Duration,
        cpuFrom start: CPUSnapshot?,
        to end: CPUSnapshot?,
        detail: String = ""
    ) {
        guard isEnabled else { return }
        var full = detail
        if let start, let end {
            let cpu = String(
                format: "cpuUserMs=%.1f cpuSysMs=%.1f",
                end.user - start.user,
                end.system - start.system
            )
            full = full.isEmpty ? cpu : full + " " + cpu
        }
        record(phase, duration, detail: full)
    }

    static func measure<T>(
        _ phase: String,
        detail: String = "",
        _ body: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = ContinuousClock.now
        let cpuStart = processCPUMilliseconds()
        defer {
            record(phase, start.duration(to: .now), detail: appendingCPUDelta(since: cpuStart, to: detail))
        }
        return try body()
    }

    static func measure<T>(
        _ phase: String,
        detail: String = "",
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let start = ContinuousClock.now
        let cpuStart = processCPUMilliseconds()
        defer {
            record(phase, start.duration(to: .now), detail: appendingCPUDelta(since: cpuStart, to: detail))
        }
        return try await body()
    }

    /// Sampled only at phase boundaries; concurrent phases would cross-attribute, but scan phases are
    /// sequential.
    private static func processCPUMilliseconds() -> (user: Double, system: Double) {
        var usage = rusage()
        #if os(Linux)
        let who = __rusage_who_t(RUSAGE_SELF.rawValue)
        #else
        let who = RUSAGE_SELF
        #endif
        guard getrusage(who, &usage) == 0 else { return (0, 0) }
        func milliseconds(_ time: timeval) -> Double {
            Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
        }
        return (milliseconds(usage.ru_utime), milliseconds(usage.ru_stime))
    }

    private static func appendingCPUDelta(
        since start: (user: Double, system: Double),
        to detail: String
    ) -> String {
        let end = processCPUMilliseconds()
        let cpu = String(
            format: "cpuUserMs=%.1f cpuSysMs=%.1f",
            end.user - start.user,
            end.system - start.system
        )
        return detail.isEmpty ? cpu : detail + " " + cpu
    }
}
