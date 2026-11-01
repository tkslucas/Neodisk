// The Linux app's entry point: route the main actor through GLib's loop,
// then hand the process to GtkApplication.

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

#if canImport(Glibc)
// An arena per scan thread kept each full rescan's freed heap resident; 4 holds RSS flat, fewer slow scans down.
mallopt(M_ARENA_MAX, 4)
#endif

DiagnosticLog.persist(to: DiagnosticLog.defaultDirectory)
DiagnosticLog.app.notice("launch \(AppChannel.current.appName) \(AppVersion.display), \(ProcessInfo.processInfo.operatingSystemVersionString)")
MainLoopBridge.install()
let application = NeodiskApplication()
exit(application.run())
