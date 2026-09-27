//
//  Accent.swift
//  NeodiskGTK
//
//  The desktop's accent color. libadwaita 1.6 follows the system accent
//  (Ubuntu's orange, a GNOME user's pick); the treemap's selection ring
//  should match the rest of the selection chrome. Looked up at run time so
//  the app still builds and runs against libadwaita 1.5.
//

import CGtk
import Glibc

@MainActor
enum Accent {
    private typealias AccentFunction = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<GdkRGBA>?

    private static let lookup: AccentFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "adw_style_manager_get_accent_color_rgba") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AccentFunction.self)
    }()

    /// Adwaita's default blue when the running libadwaita predates system
    /// accents.
    static var color: RGBA {
        guard let lookup, let rgba = lookup(adw_style_manager_get_default()) else {
            return RGBA(red: 0.21, green: 0.52, blue: 0.89)
        }
        defer { gdk_rgba_free(rgba) }
        return RGBA(red: rgba.pointee.red, green: rgba.pointee.green, blue: rgba.pointee.blue)
    }
}
