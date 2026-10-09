//
//  DiagnosticsMonitor.swift
//  Neodisk
//

import AppKit
import MetricKit
import NeodiskAppModel
import NeodiskKit

/// Watches the app from inside, kept in `~/Library/Logs/<app>` until exported: the log file,
/// unclean exits, main-thread stalls, memory and MetricKit's crash and hang reports.
@MainActor
enum DiagnosticsMonitor {
    static var directory: URL { DiagnosticLog.defaultDirectory }

    private static var marker: URL { directory.appending(path: "running") }
    private static var metricKitDirectory: URL { directory.appending(path: "MetricKit", directoryHint: .isDirectory) }
    private static var started = false
    private static let metricKitReceiver = MetricKitReceiver()
    private static var memorySampler: DispatchSourceTimer?

    static func start() {
        guard !started else { return }
        started = true
        DiagnosticLog.persist(to: directory)
        let process = ProcessInfo.processInfo
        DiagnosticLog.app.notice(
            "launch \(AppChannel.current.appName) \(AppVersion.display), macOS \(process.operatingSystemVersionString), "
            + "\(SystemInfo.model), \(process.activeProcessorCount) cores, "
            + "\(MemoryFootprint.megabytes(process.physicalMemory) / 1024) GB"
        )
        checkPreviousExit()
        MainThreadStallObserver.install()
        memorySampler = makeMemorySampler()
        MXMetricManager.shared.add(metricKitReceiver)
        let marker = marker
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            DiagnosticLog.app.notice("quit; \(MemoryFootprint.summary())")
            try? FileManager.default.removeItem(at: marker)
        }
    }

    /// Crash reports macOS wrote for this app, newest first.
    static func crashReports(since date: Date = .distantPast) -> [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "Neodisk"
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reports, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(executable + "-") || $0.lastPathComponent.hasPrefix(executable + "_") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .filter { $0.1 >= date }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static var metricKitPayloads: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: metricKitDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - Unclean exit

    private static func checkPreviousExit() {
        if let previous = try? String(contentsOf: marker, encoding: .utf8) {
            let startedAt = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let reports = crashReports(since: startedAt)
            DiagnosticLog.app.error(
                "previous session (\(previous)) did not quit cleanly"
                + (reports.isEmpty ? "; no crash report" : "; crash report \(reports[0].lastPathComponent)")
            )
        }
        let session = "\(AppVersion.display), pid \(ProcessInfo.processInfo.processIdentifier)"
        try? session.write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Memory

    /// Logs memory when it moves 20% (or hourly); warns past a quarter of RAM.
    private nonisolated static func makeMemorySampler() -> DispatchSourceTimer {
        let queue = DispatchQueue(label: "Neodisk.MemorySampler", qos: .utility)
        let warnAt = ProcessInfo.processInfo.physicalMemory / 4
        let timer = DispatchSource.makeTimerSource(queue: queue)
        nonisolated(unsafe) var lastLogged: UInt64 = 0
        nonisolated(unsafe) var lastLoggedAt = ContinuousClock.now
        nonisolated(unsafe) var warned = false
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { @Sendable in
            guard let reading = MemoryFootprint.read() else { return }
            let moved = Double(reading.current) / Double(max(lastLogged, 1))
            if moved > 1.2 || moved < 0.8 || ContinuousClock.now - lastLoggedAt > .seconds(3600) {
                DiagnosticLog.memory.info(MemoryFootprint.summary())
                lastLogged = reading.current
                lastLoggedAt = .now
            }
            if reading.current > warnAt, !warned {
                DiagnosticLog.memory.warning("above a quarter of RAM: \(MemoryFootprint.summary())")
            }
            warned = reading.current > warnAt
        }
        timer.resume()
        return timer
    }
}

// MARK: - Main-thread stalls

/// Times each main run-loop pass from wake to sleep; no timer, so an idle app costs nothing.
private enum MainThreadStallObserver {
    @MainActor
    static func install() {
        nonisolated(unsafe) var wokeAt: SuspendingClock.Instant?
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            if activity == .afterWaiting {
                wokeAt = .now
                return
            }
            guard let start = wokeAt else { return }
            wokeAt = nil
            let busy = SuspendingClock.now - start
            guard busy >= .milliseconds(500) else { return }
            let seconds = Double(busy.components.seconds) + Double(busy.components.attoseconds) / 1e18
            DiagnosticLog.performance.log(
                busy >= .seconds(2) ? .warning : .notice,
                "main thread busy for \(seconds.formatted(.number.precision(.fractionLength(2))))s"
            )
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

// MARK: - MetricKit

/// Saves each MetricKit payload as JSON and logs what it reports.
private final class MetricKitReceiver: NSObject, MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let counts: [(String, Int)] = [
                ("crashes", payload.crashDiagnostics?.count ?? 0),
                ("hangs", payload.hangDiagnostics?.count ?? 0),
                ("cpu exceptions", payload.cpuExceptionDiagnostics?.count ?? 0),
                ("disk write exceptions", payload.diskWriteExceptionDiagnostics?.count ?? 0)
            ]
            let summary = counts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
            DiagnosticLog.app.warning("system diagnostics: \(summary.isEmpty ? "none" : summary)")
            save(payload.jsonRepresentation(), kind: "diagnostics", end: payload.timeStampEnd)
        }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "metrics", end: payload.timeStampEnd)
        }
    }

    private nonisolated func save(_ json: Data, kind: String, end: Date) {
        let directory = DiagnosticLog.defaultDirectory.appending(path: "MetricKit", directoryHint: .isDirectory)
        let name = "\(kind)-\(end.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))"
            .replacingOccurrences(of: ":", with: "")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try json.write(to: directory.appending(path: name + ".json"), options: .atomic)
        } catch {
            DiagnosticLog.app.warning("could not save MetricKit \(kind): \(error)")
        }
    }
}

enum SystemInfo {
    /// The hardware model identifier, e.g. `MacBookAir10,1`.
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
