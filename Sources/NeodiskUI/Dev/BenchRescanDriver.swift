// Times in-app rescans (no decode or launch, unlike a relaunch bench): NEODISK_BENCH_RESCANS, _RESCAN_INTERVAL
// (default 60s), _TARGETS (memory soak, issue #9), _STAY=1; NEODISK_INCREMENTAL=0 forces full re-traversal.

import AppKit
import Foundation
import NeodiskKit

@MainActor
final class BenchRescanDriver {
    static let shared = BenchRescanDriver()

    private var remaining = 0
    private var interval: Duration = .seconds(60)
    private weak var model: NeodiskViewModel?
    private var armed = false
    private var sawInitialScan = false
    private var targets: [ScanTarget] = []
    private var step = 0

    /// Arms the driver if NEODISK_BENCH_RESCANS is set. Safe to call more than
    /// once (per window onAppear); only the first arms.
    func startIfRequested(model: NeodiskViewModel) {
        guard !armed,
              let raw = ProcessInfo.processInfo.environment["NEODISK_BENCH_RESCANS"],
              let count = Int(raw), count > 0 else { return }
        armed = true
        remaining = count
        self.model = model
        if let rawInterval = ProcessInfo.processInfo.environment["NEODISK_BENCH_RESCAN_INTERVAL"],
           let seconds = Double(rawInterval) {
            interval = .seconds(seconds)
        }
        targets = (ProcessInfo.processInfo.environment["NEODISK_BENCH_TARGETS"] ?? "")
            .split(separator: ":")
            .map { ScanTarget(url: URL(filePath: String($0), directoryHint: .isDirectory)) }
        ScanTiming.note("bench: in-app rescan driver armed, \(count) rescans")
        FeltTiming.onEpisodeDisplayed = { [weak self] in self?.episodeDisplayed() }
    }

    private func episodeDisplayed() {
        guard armed else { return }
        if !sawInitialScan {
            // The initial NEODISK_AUTOSCAN just displayed; begin the rescan loop.
            sawInitialScan = true
            scheduleNextRescan()
            return
        }
        remaining -= 1
        if remaining <= 0 {
            if ProcessInfo.processInfo.environment["NEODISK_BENCH_STAY"] == nil { terminate() }
        } else {
            scheduleNextRescan()
        }
    }

    private func scheduleNextRescan() {
        let model = model
        let target = targets.isEmpty || step % 2 == 0 ? nil : targets[(step / 2) % targets.count]
        step += 1
        Task { @MainActor in
            try? await Task.sleep(for: interval)
            // forcesRescan: refresh the on-screen target with its in-memory
            // snapshot as the incremental baseline — the in-app rescan path.
            if let target { model?.startScan(target, forcesRescan: true) } else { model?.rescan() }
        }
    }

    private func terminate() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
    }
}
