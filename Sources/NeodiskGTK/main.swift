//
//  main.swift
//  NeodiskGTK
//
//  The Linux app's entry point: route the main actor through GLib's loop,
//  then hand the process to GtkApplication.
//

import CGtk
import Foundation
import NeodiskAppModel
import NeodiskKit

DiagnosticLog.persist(to: DiagnosticLog.defaultDirectory)
DiagnosticLog.app.notice("launch \(AppChannel.current.appName) \(AppVersion.display), \(ProcessInfo.processInfo.operatingSystemVersionString)")
MainLoopBridge.install()
let application = NeodiskApplication()
exit(application.run())
