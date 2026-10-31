// GtkFileLauncher goes through the portal or FileManager1 D-Bus, so "Show in Files" selects the item
// in whatever file manager the desktop uses. The only change Neodisk makes is a confirmed move to the Trash.

import CGtk
import Foundation
import NeodiskKit

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

/// GIO's Trash (the freedesktop.org one), where the file manager can restore items. A filesystem without a
/// trash fails the move with GIO's reason and the item stays put: Neodisk never falls back to deleting.
enum GioTrash {
    static let trashItem: TrashMover.TrashItem = { url in
        let file = g_file_new_for_path(url.path)
        defer { g_object_unref(raw(file)) }
        var error: UnsafeMutablePointer<GError>?
        if g_file_trash(file, nil, &error) != 0 { return nil }
        defer { if let error { g_error_free(error) } }
        let message = error.flatMap { string(from: $0.pointee.message) } ?? L("The item couldn't be moved to the Trash.")
        let domain = error.flatMap { string(from: g_quark_to_string($0.pointee.domain)) } ?? "g-io-error-quark"
        throw NSError(domain: domain, code: Int(error?.pointee.code ?? 0), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
