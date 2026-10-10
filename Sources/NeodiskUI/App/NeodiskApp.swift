//
//  NeodiskApp.swift
//  Neodisk
//

import AppKit
import SwiftUI
import NeodiskKit

public struct NeodiskApp: App {
    @State private var model: NeodiskViewModel
    @StateObject private var preferences: AppPreferences
    // Sparkle auto-updates; inert (no updater) for unbundled `swift run`
    // builds and bundles without an appcast feed. See UpdateController.
    @StateObject private var updates = UpdateController()

    public init() {
        FeltTiming.markLaunch("appInit")
        DiagnosticsMonitor.start()
        // Route cloud-kind targets to the CloudScan service (fixture-fed in
        // M1; nil in builds without CloudScanKit, where the router's cloud
        // leg reports the feature as unavailable).
        let cloudScan = CloudScanFactory.make()
        let model = NeodiskViewModel(
            coordinator: ScanCoordinator(
                scanService: RoutingScanService(cloudService: cloudScan?.scanService)
            ),
            cloudScan: cloudScan
        )
        // Bound before the first frame, so the workspace opens at the saved
        // text size. Binding on appear drew one frame at 100% first, and a
        // control that took focus there kept its 100% focus ring on macOS 26.
        let preferences = AppPreferences()
        model.preferences = preferences
        _model = State(initialValue: model)
        _preferences = StateObject(wrappedValue: preferences)
        FeltTiming.markLaunch("modelReady")

        // Single-window app: no window tabs, so the View menu loses the
        // useless "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Running via `swift run` there is no app bundle, so opt into being a
        // regular foreground app with a menu bar and key window — unless a
        // headless run is requested (NEODISK_UI_SNAPSHOT capture or a
        // NEODISK_HEADLESS bench run), in which case stay an accessory app and
        // never activate, so the window does not appear on screen or steal
        // focus (it is also moved offscreen and kept transparent; see
        // SnapshotWindowHider and HeadlessMode).
        let app = NSApplication.shared
        if HeadlessMode.isOffscreen {
            if app.activationPolicy() != .accessory {
                app.setActivationPolicy(.accessory)
            }
        } else {
            if app.activationPolicy() != .regular {
                app.setActivationPolicy(.regular)
            }
            DispatchQueue.main.async {
                app.activate(ignoringOtherApps: true)
            }
        }
    }

    public var body: some Scene {
        WindowGroup {
            ContentView(model: model, preferences: preferences, updates: updates)
                .onAppear { preferences.applyTheme() }
        }
        .commands {
            NeodiskCommands(model: model, updates: updates)
        }

        Settings {
            SettingsView(model: model, preferences: preferences, updates: updates)
        }

        Window("About \(AppChannel.current.appName)", id: "about") {
            AboutView()
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
