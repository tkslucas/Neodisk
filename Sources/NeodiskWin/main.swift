// The Windows app's entry point: COM and the common controls, the shared string catalogs, the model and the
// main window, then the message loop (which also drains the main dispatch queue for @MainActor work).

import CNeodiskWin
import Foundation
import NeodiskAppModel
import NeodiskKit
import WinSDK

DiagnosticLog.persist(to: DiagnosticLog.defaultDirectory)
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
