//
//  FeltTiming.swift
//  Neodisk
//
//  App-level "felt time" instrumentation: the wall/CPU cost of what the user
//  actually waits on, which the engine-phase NEODISK_SCAN_TIMING lines do not
//  capture (they stop at the engine boundary; the UI tail — splice apply,
//  treemap layout, first render — is unmeasured, and reopening a scan runs
//  snapshot-restore + incremental rescan, not a full scan). Active only under
//  NEODISK_SCAN_TIMING=1, driven by INSTRUCTIONS/scripts/app-bench.sh.
//
//  Marks are emitted through NeodiskKit's ScanTiming so the line format stays
//  a single contract:
//    app.launchToScanStart        process creation → first scan/restore begins
//    app.firstPartialDisplayed    scan start → first tree committed to the map
//                                 (for a rescan this is the cached map showing)
//    app.scanFinishedToTreeDisplayed  engine finished → final tree on the map
//    app.feltTotal                scan start → final interactive tree on the map
//  Every episode's marks carry one resolved `mode=full|restore|rescan`.
//
//  The three per-episode marks are buffered and emitted together when the
//  final tree is displayed: the full-vs-rescan distinction is only settled
//  then (the cold-launch index race routes first scans through the same
//  optimistic-refresh path a real rescan takes), and emitting at the end keeps
//  every line of one episode tagged with the same mode.
//
//  "Displayed" means pixels committed to the treemap layer (the render task's
//  push), correlated by snapshot id — not where the event arrived.
//

import AppKit
import Foundation
import NeodiskKit

@MainActor
enum FeltTiming {
    enum Mode: String {
        case full
        case restore
        case rescan
    }

    static let isEnabled = ScanTiming.isEnabled
    private static let autoQuit =
        ProcessInfo.processInfo.environment["NEODISK_BENCH_AUTOQUIT"] == "1"
    /// When the in-app rescan driver is measuring repeated rescans it owns the
    /// quit (after the last rescan), so a per-episode autoquit must not fire.
    private static let driverOwnsQuit =
        ProcessInfo.processInfo.environment["NEODISK_BENCH_RESCANS"] != nil

    /// Fires each time a scan/rescan episode's final tree is displayed — the
    /// signal the in-app rescan driver sequences on (see BenchRescanDriver).
    static var onEpisodeDisplayed: (() -> Void)?

    /// Process creation time (includes dyld + runtime init), read once from
    /// the kernel — the honest start of "launch", before any of our code runs.
    private static let processStartDate: Date? = readProcessStartDate()

    private struct Sample {
        let instant: ContinuousClock.Instant
        let cpu: ScanTiming.CPUSnapshot
        static var now: Sample { Sample(instant: .now, cpu: ScanTiming.cpuSnapshot()) }
    }

    private static var scanStart: Sample?
    /// Restore is known at scan start; full vs rescan is only known once we see
    /// whether a cached complete map was displayed before the engine finished.
    private static var isRestore = false
    private static var sawCachedDisplay = false
    private static var launchMarkEmitted = false

    private static var firstDisplay: Sample?
    private static var engineFinished: Sample?
    /// The snapshot whose display ends the felt interval — the engine's
    /// finished snapshot for a scan/rescan, or the restored one for a restore.
    private static var finalSnapshotID: UUID?
    private static var finalEmitted = false

    private static var mode: Mode {
        if isRestore { return .restore }
        // A cached map shown but no engine scan behind it is a restore; with a
        // completed engine scan it is a rescan; neither is a from-zero full.
        if sawCachedDisplay { return engineFinished == nil ? .restore : .rescan }
        return .full
    }

    // MARK: - Signals from the model / view

    /// Launch milestone: `app.launch.<name>` with the time since process
    /// creation, for finding where launch-to-scan goes.
    static func markLaunch(_ name: String) {
        guard isEnabled, !launchMarkEmitted, let processStartDate else { return }
        let wall = Duration.seconds(Date().timeIntervalSince(processStartDate))
        ScanTiming.record("app.launch.\(name)", wall, cpuFrom: nil, to: nil)
    }

    /// A scan or rescan of the launch target begins. Resets the per-episode
    /// state and, once per process, emits `app.launchToScanStart`.
    static func noteScanStart(restore: Bool = false) {
        guard isEnabled else { return }
        MainThreadMonitor.startIfProfiling()
        scanStart = .now
        isRestore = restore
        sawCachedDisplay = false
        firstDisplay = nil
        engineFinished = nil
        finalSnapshotID = nil
        finalEmitted = false

        if !launchMarkEmitted, let processStartDate {
            launchMarkEmitted = true
            // Mode-independent: process creation → the app asking for a scan.
            let wall = Duration.seconds(Date().timeIntervalSince(processStartDate))
            ScanTiming.record("app.launchToScanStart", wall, cpuFrom: nil, to: nil)
        }
    }

    /// A cached, complete map was put on screen before any fresh scan
    /// finished — the app restored/refreshed rather than scanning from zero.
    static func noteCachedSnapshotDisplayed() {
        guard isEnabled, scanStart != nil else { return }
        sawCachedDisplay = true
    }

    /// The engine delivered the final (complete) snapshot for a scan/rescan.
    static func noteEngineFinished(snapshotID: UUID) {
        guard isEnabled, scanStart != nil else { return }
        engineFinished = .now
        finalSnapshotID = snapshotID
    }

    /// A cached snapshot was restored for display with no engine scan behind
    /// it — its display is the end of the felt interval.
    static func noteRestoreCompleted(snapshotID: UUID) {
        guard isEnabled, scanStart != nil else { return }
        finalSnapshotID = snapshotID
    }

    /// The treemap committed a rendered image for `snapshotID`. The first such
    /// commit records the first-partial instant; the commit of the final
    /// snapshot flushes the episode's marks (and triggers auto-quit).
    static func noteTreemapDisplayed(snapshotID: UUID?) {
        guard isEnabled, scanStart != nil else { return }
        if firstDisplay == nil {
            firstDisplay = .now
        }
        guard let finalSnapshotID, snapshotID == finalSnapshotID, !finalEmitted else { return }
        finalEmitted = true
        flush(finalDisplay: .now)
    }

    // MARK: - Emission

    private static func flush(finalDisplay: Sample) {
        guard let scanStart else { return }
        let resolvedMode = mode
        let detail = "mode=\(resolvedMode.rawValue)"
        let first = firstDisplay ?? finalDisplay

        ScanTiming.record(
            "app.firstPartialDisplayed",
            scanStart.instant.duration(to: first.instant),
            cpuFrom: scanStart.cpu, to: first.cpu, detail: detail
        )
        if let engineFinished {
            ScanTiming.record(
                "app.scanFinishedToTreeDisplayed",
                engineFinished.instant.duration(to: finalDisplay.instant),
                cpuFrom: engineFinished.cpu, to: finalDisplay.cpu, detail: detail
            )
        }
        ScanTiming.record(
            "app.feltTotal",
            scanStart.instant.duration(to: finalDisplay.instant),
            cpuFrom: scanStart.cpu, to: finalDisplay.cpu, detail: detail
        )

        ScanProfile.emitNamed()
        onEpisodeDisplayed?()
        if autoQuit && !driverOwnsQuit {
            scheduleQuit()
        }
    }

    // MARK: - Auto-quit

    private static func scheduleQuit() {
        // Let stderr flush the marks, then terminate cleanly so the harness
        // measures a real launch→quit lifecycle.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.terminate(nil)
        }
    }

    // MARK: - Process start

    private static func readProcessStartDate() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard rc == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let seconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }
}
