// Dev hooks named like the other apps': NEODISK_AUTOSCAN=<path> scans on launch; NEODISK_UI_SNAPSHOT=<out.png>
// saves the window as PNG once the scan is on screen (NEODISK_SNAPSHOT_DELAY seconds later), then quits.
// NEODISK_SELECT=<path> selects an item once shown. NEODISK_THEME=light|dark and NEODISK_SCALE=<factor> are
// read where the theme and the DPI scale are.
//
// A clean profile, as a first launch sees it: APPDATA=<dir> moves settings.json (the sidebar's folders, the
// window, the view) and NEODISK_SNAPSHOT_DIR=<dir> the saved scans. NEODISK_DATA_DIR isn't one of them: as on
// Linux, it's where the Localization catalogs are read from.

import CNeodiskWin
import Foundation
import NeodiskAppModel
import NeodiskKit
import WinSDK

@MainActor
enum DevHooks {
    private static var observations: [ChangeObservation] = []

    static func run(controller: AppController) {
        let environment = ProcessInfo.processInfo.environment
        let workspace = controller.model.workspace
        if let mode = environment["NEODISK_VIZ_MODE"].flatMap(VizViewMode.init(rawValue:)) {
            controller.model.settings.vizMode = mode
        }
        if let path = environment["NEODISK_AUTOSCAN"], !path.isEmpty {
            controller.model.openFolder(path)
        }
        if let path = environment["NEODISK_SELECT"] {
            var done = false
            observations.append(observeChanges {
                guard !done, workspace.phase == .displaying, let store = workspace.store else { return }
                let id = ScanTarget(url: URL(filePath: path)).id
                guard store.node(id: id) != nil || store.node(id: path) != nil else { return }
                done = true
                workspace.select(store.node(id: id) != nil ? id : path)
            })
        }
        guard let output = environment["NEODISK_UI_SNAPSHOT"], !output.isEmpty else { return }
        let delay = environment["NEODISK_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
        let waitsForScan = environment["NEODISK_AUTOSCAN"] != nil
        var captured = false
        observations.append(observeChanges {
            guard !captured, !waitsForScan || workspace.phase == .displaying else { return }
            captured = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let window = controller.window.hwnd
                SetForegroundWindow(window)
                DwmFlush()
                let fromScreen: Int32 = environment["NEODISK_SNAPSHOT_PRINTWINDOW"] == nil ? 1 : 0
                let result = ndw_capture_window_png(window, output.wide, fromScreen)
                DiagnosticLog.app.notice("snapshot \(output): \(result == 0 ? "written" : "failed")")
                PostMessageW(window, UINT(WM_CLOSE), 0, 0)
            }
        })
    }
}
