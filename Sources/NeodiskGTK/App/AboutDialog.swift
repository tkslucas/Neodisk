//
//  AboutDialog.swift
//  NeodiskGTK
//

import CGtk
import Foundation
import NeodiskAppModel

@MainActor
enum AboutDialog {
    static func present(from window: GPtr?) {
        let dialog = adw_about_dialog_new()
        adw_about_dialog_set_application_name(OpaquePointer(dialog), "Neodisk")
        adw_about_dialog_set_application_icon(OpaquePointer(dialog), NeodiskApplication.applicationID)
        adw_about_dialog_set_version(OpaquePointer(dialog), AppVersion.string)
        adw_about_dialog_set_developer_name(OpaquePointer(dialog), "Lucas Takayasu")
        adw_about_dialog_set_comments(
            OpaquePointer(dialog),
            L("Read-only disk space visualizer. Treemap and sunburst views on the NeodiskKit scan engine.")
        )
        adw_about_dialog_set_website(OpaquePointer(dialog), "https://github.com/tkslucas/Neodisk")
        adw_about_dialog_set_issue_url(OpaquePointer(dialog), "https://github.com/tkslucas/Neodisk/issues")
        adw_about_dialog_set_license_type(OpaquePointer(dialog), GTK_LICENSE_GPL_3_0)
        adw_dialog_present(dialog, ptr(window))
    }
}
