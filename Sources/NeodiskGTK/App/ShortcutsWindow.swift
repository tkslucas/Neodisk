//
//  ShortcutsWindow.swift
//  NeodiskGTK
//
//  The keyboard-shortcuts overlay (Ctrl+? in GNOME apps, and the main
//  menu's Keyboard Shortcuts). Built from GtkBuilder markup, the form GTK
//  documents for GtkShortcutsWindow; titles go through the shared catalogs.
//

import CGtk
import Foundation

@MainActor
enum ShortcutsWindow {
    private struct Shortcut {
        let title: String
        let accelerator: String
    }

    private static let sections: [(String, [Shortcut])] = [
        (L("General"), [
            Shortcut(title: L("Choose Folder…"), accelerator: "<Control>o"),
            Shortcut(title: L("Rescan"), accelerator: "<Control>r F5"),
            Shortcut(title: L("Stop Scan"), accelerator: "<Control>period"),
            Shortcut(title: L("Search"), accelerator: "<Control>f"),
            Shortcut(title: L("Toggle Sidebar"), accelerator: "F9"),
            Shortcut(title: L("Preferences"), accelerator: "<Control>comma"),
            Shortcut(title: L("Quit"), accelerator: "<Control>q"),
        ]),
        (L("Visualization"), [
            Shortcut(title: L("Cushion Treemap"), accelerator: "<Control>1"),
            Shortcut(title: L("Flat Treemap"), accelerator: "<Control>2"),
            Shortcut(title: L("Sunburst"), accelerator: "<Control>3"),
            Shortcut(title: L("Zoom In"), accelerator: "<Control>Down Return"),
            Shortcut(title: L("Zoom Out"), accelerator: "<Control>Up BackSpace"),
            Shortcut(title: L("Move Selection"), accelerator: "Left Right Up Down"),
        ]),
        (L("Selection"), [
            Shortcut(title: L("Open"), accelerator: "<Control>Return"),
            Shortcut(title: L("Copy Path"), accelerator: "<Control><Shift>c"),
        ]),
    ]

    static func present(from window: GPtr?) {
        let groups = sections.map { title, shortcuts in
            let items = shortcuts.map { shortcut in
                """
                <child><object class="GtkShortcutsShortcut">
                  <property name="title">\(escape(shortcut.title))</property>
                  <property name="accelerator">\(escape(shortcut.accelerator))</property>
                </object></child>
                """
            }.joined()
            return """
            <child><object class="GtkShortcutsGroup">
              <property name="title">\(escape(title))</property>
              \(items)
            </object></child>
            """
        }.joined()
        let markup = """
        <interface>
          <object class="GtkShortcutsWindow" id="shortcuts">
            <property name="modal">true</property>
            <child><object class="GtkShortcutsSection">
              <property name="section-name">main</property>
              \(groups)
            </object></child>
          </object>
        </interface>
        """
        guard let builder = gtk_builder_new_from_string(markup, -1) else { return }
        defer { g_object_unref(raw(builder)) }
        guard let shortcuts = gtk_builder_get_object(builder, "shortcuts") else { return }
        gtk_window_set_transient_for(ptr(raw(shortcuts)), ptr(window))
        gtk_window_present(ptr(raw(shortcuts)))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
