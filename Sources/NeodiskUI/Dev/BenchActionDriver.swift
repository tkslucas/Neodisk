// Times interactions after a scan: NEODISK_BENCH_ACTIONS="<action>;<action>…" runs each once the scan settles,
// 1.5 s apart, then quits. With NEODISK_SCAN_PROFILE=1 the main-thread monitor logs every stall over 100 ms
// against the same clock, so each stall maps to the action that caused it. Inert unless set.
// Actions: select:<path>, drill:<path>, out, tab:<largest|kinds|age|duplicates|changes>, stats:<hide|show>,
// viz:<treemap|sunburst>, rescan.

import AppKit
import Foundation
import NeodiskKit
import NeodiskAppModel

@MainActor
enum BenchActionDriver {
    static func startIfRequested(model: NeodiskViewModel) {
        guard let raw = ProcessInfo.processInfo.environment["NEODISK_BENCH_ACTIONS"] else { return }
        let actions = raw.split(separator: ";").map(String.init)
        Task { @MainActor in
            for _ in 0..<400 {
                try? await Task.sleep(for: .milliseconds(250))
                if !model.coordinator.isScanning, model.coordinator.snapshot?.isComplete == true { break }
            }
            try? await Task.sleep(for: .seconds(2))
            for action in actions {
                ScanTiming.note("benchAction atMs=\(MainThreadMonitor.elapsedMs) \(action)")
                run(action, model: model)
                try? await Task.sleep(for: .milliseconds(1500))
            }
            MainThreadMonitor.emitStallStacks()
            NSApp.terminate(nil)
        }
    }

    private static func run(_ action: String, model: NeodiskViewModel) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "select":
            model.select(DevLaunchHooks.findNode(at: argument, in: model)?.id)
        case "drill":
            if let id = DevLaunchHooks.findNode(at: argument, in: model)?.id { _ = model.drillIn(to: id) }
        case "out":
            _ = model.drillOut()
        case "tab":
            if let tab = AnalysisTab(rawValue: argument) { model.analysisTab = tab }
        case "stats":
            model.showKindStats = argument == "show"
        case "viz":
            if let mode = VizViewMode(rawValue: argument) { model.vizViewMode = mode }
        case "rescan":
            model.rescan()
        default:
            ScanTiming.note("benchAction unknown \(action)")
        }
    }
}
