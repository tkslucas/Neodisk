//
//  main.swift
//  NeodiskGTK
//
//  The Linux app's entry point: route the main actor through GLib's loop,
//  then hand the process to GtkApplication.
//

import CGtk
import Foundation

MainLoopBridge.install()
let application = NeodiskApplication()
exit(application.run())
