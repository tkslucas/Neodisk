//
//  NeodiskApplication.swift
//  NeodiskGTK
//
//  The AdwApplication: single instance (a second launch raises the existing
//  window), application-wide actions and keyboard accelerators, the style
//  sheet, and the platform seams the shared model needs filled in (file
//  type descriptions from GIO's shared-mime-info).
//

import CGtk
import Foundation
import NeodiskAppModel

@MainActor
final class NeodiskApplication {
    /// The reverse-DNS identity the macOS bundle uses; also the D-Bus name,
    /// the .desktop file name, and the icon name.
    static let applicationID = "com.lucastakayasu.Neodisk"

    let app: GPtr
    let preferences = Preferences()
    let model: AppModel
    private var window: MainWindow?

    init() {
        model = AppModel(preferences: preferences)
        app = raw(adw_application_new(Self.applicationID, GApplicationFlags(rawValue: 0)))!
        g_set_application_name("Neodisk")
        connect(app, "startup") { [unowned self] in self.startup() }
        connect(app, "activate") { [unowned self] in self.activate() }
        connect(app, "shutdown") { [unowned self] in self.preferences.saveNow() }
    }

    func run() -> Int32 {
        g_application_run(ptr(app), CommandLine.argc, CommandLine.unsafeArgv)
    }

    private func startup() {
        FileTypeDescriptions.install { fileExtension in
            guard let type = g_content_type_guess("file.\(fileExtension)", nil, 0, nil) else { return nil }
            defer { g_free(type) }
            guard g_content_type_is_unknown(type) == 0 else { return nil }
            return takeString(g_content_type_get_description(type))
        }
        Styles.install()
        applyColorScheme()
        track { [unowned self] in
            _ = self.preferences.colorScheme
            self.applyColorScheme()
        }
        installActions()
    }

    private func activate() {
        if let window {
            gtk_window_present(ptr(window.window))
            return
        }
        let window = MainWindow(application: app, model: model)
        self.window = window
        window.present()
        DevLaunchHooks.run(model: model, window: window, application: app)
    }

    private func applyColorScheme() {
        let manager = adw_style_manager_get_default()
        switch preferences.colorScheme {
        case .system: adw_style_manager_set_color_scheme(manager, ADW_COLOR_SCHEME_DEFAULT)
        case .light: adw_style_manager_set_color_scheme(manager, ADW_COLOR_SCHEME_FORCE_LIGHT)
        case .dark: adw_style_manager_set_color_scheme(manager, ADW_COLOR_SCHEME_FORCE_DARK)
        }
    }

    private func installActions() {
        addAction(to: app, "quit") { [unowned self] _ in
            g_application_quit(ptr(self.app))
        }
        addAction(to: app, "about") { [unowned self] _ in
            AboutDialog.present(from: self.window?.window)
        }
        addAction(to: app, "preferences") { [unowned self] _ in
            guard let window = self.window else { return }
            PreferencesDialog.present(model: self.model, from: window.window)
        }
        setAccelerators("app.quit", ["<Control>q"])
        setAccelerators("app.preferences", ["<Control>comma"])
        setAccelerators("win.open-folder", ["<Control>o"])
        setAccelerators("win.rescan", ["<Control>r", "F5"])
        setAccelerators("win.stop", ["<Control>period"])
        setAccelerators("win.search", ["<Control>f"])
        setAccelerators("win.focus-in", ["<Control>Down"])
        setAccelerators("win.focus-out", ["<Control>Up", "<Alt>Up"])
        setAccelerators("win.toggle-sidebar", ["F9"])
        setAccelerators("win.show-treemap", ["<Control>1"])
        setAccelerators("win.show-sunburst", ["<Control>2"])
        setAccelerators("win.open-item", ["<Control>Return"])
        setAccelerators("win.copy-path", ["<Control><Shift>c"])
    }

    private func setAccelerators(_ action: String, _ accelerators: [String]) {
        var cStrings = accelerators.map { strdup($0) }
        cStrings.append(nil)
        cStrings.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                gtk_application_set_accels_for_action(ptr(app), action, $0)
            }
        }
        cStrings.forEach { free($0) }
    }
}
