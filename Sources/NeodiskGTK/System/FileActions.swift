//
//  FileActions.swift
//  NeodiskGTK
//
//  The read-only file actions, as on the Mac: open, show in the file
//  manager, copy the path. GtkFileLauncher goes through the desktop portal
//  or the FileManager1 D-Bus interface, so "Show in Files" selects the item
//  in whichever file manager the desktop uses (Nautilus, Thunar, Dolphin).
//  Neodisk never modifies or deletes files.
//

import CGtk
import Foundation

@MainActor
enum FileActions {
    static func open(_ path: String, from window: GPtr?) {
        let file = g_file_new_for_path(path)
        defer { g_object_unref(raw(file)) }
        let launcher = gtk_file_launcher_new(file)
        gtk_file_launcher_launch(launcher, ptr(window), nil, nil, nil)
        g_object_unref(raw(launcher))
    }

    static func showInFileManager(_ path: String, from window: GPtr?) {
        let file = g_file_new_for_path(path)
        defer { g_object_unref(raw(file)) }
        let launcher = gtk_file_launcher_new(file)
        gtk_file_launcher_open_containing_folder(launcher, ptr(window), nil, nil, nil)
        g_object_unref(raw(launcher))
    }

    static func copyPath(_ path: String, from widget: GPtr?) {
        let clipboard = gtk_widget_get_clipboard(ptr(widget))
        gdk_clipboard_set_text(clipboard, path)
    }
}
