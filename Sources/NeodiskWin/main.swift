// The Windows app's entry point: COM and the common controls, the shared string catalogs, the model and the
// main window, then the message loop (which also drains the main dispatch queue for @MainActor work).

import CNeodiskWin
import Foundation
import NeodiskAppModel
import NeodiskKit
import WinSDK

// A GUI process has no stderr unless it was redirected, and writing to the missing handle traps.
let standardError = GetStdHandle(STD_ERROR_HANDLE)
if standardError == nil || standardError == INVALID_HANDLE_VALUE {
    _ = SetEnvironmentVariableW("NEODISK_LOG_STDERR".wide, "0".wide)
}
DiagnosticLog.persist(to: logDirectory())
DiagnosticLog.app.notice("launch \(AppChannel.current.appName) \(AppVersion.display), \(ProcessInfo.processInfo.operatingSystemVersionString)")

// The canvas's own dev hooks: a demo window, a benchmark, headless renders.
if CanvasDemo.isRequested {
    exit(MainActor.assumeIsolated { CanvasDemo.run() })
}

let exitCode: Int32 = MainActor.assumeIsolated {
    _ = ndw_initialize()
    Strings.table = AppLocalization.load()
    AppStrings.install { L($0) }
    let model = ShellModel(settings: Settings())
    let controller = AppController(model: model)
    controller.show()
    DevHooks.run(controller: controller)
    let code = MessageLoop.run()
    model.settings.saveNow()
    return code
}
exit(exitCode)

/// %LOCALAPPDATA%\Neodisk\Logs; NEODISK_LOG_DIR overrides.
func logDirectory() -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["NEODISK_LOG_DIR"], !override.isEmpty {
        return URL(filePath: override, directoryHint: .isDirectory)
    }
    guard let local = environment["LOCALAPPDATA"], !local.isEmpty else { return DiagnosticLog.defaultDirectory }
    return URL(filePath: local, directoryHint: .isDirectory).appending(path: "\(AppChannel.current.appName)/Logs")
}
