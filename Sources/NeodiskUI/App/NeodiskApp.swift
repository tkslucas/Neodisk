//
//  NeodiskApp.swift
//  Neodisk
//

import AppKit
import SwiftUI

public struct NeodiskApp: App {
    @State private var model = NeodiskViewModel()
    @StateObject private var preferences = AppPreferences()
    // Sparkle auto-updates; inert (no updater) for unbundled `swift run`
    // builds and bundles without an appcast feed. See UpdateController.
    @StateObject private var updates = UpdateController()

    public init() {
        // Single-window app: no window tabs, so the View menu loses the
        // useless "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Running via `swift run` there is no app bundle, so opt into being a
        // regular foreground app with a menu bar and key window — unless a
        // headless snapshot is requested (NEODISK_UI_SNAPSHOT), in which case
        // stay an accessory app and never activate, so the capture window
        // does not appear on screen or steal focus (it is also moved offscreen
        // and kept transparent; see SnapshotWindowHider).
        let app = NSApplication.shared
        if ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] != nil {
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
            CommandGroup(replacing: .appInfo) {
                Button("About Neodisk") {
                    AboutPanel.show()
                }
            }

            CommandGroup(after: .appInfo) {
                Button {
                    updates.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updates.canCheckForUpdates)
            }

            CommandGroup(replacing: .newItem) {
                Button {
                    model.chooseFolderAndScan()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o")

                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(!model.coordinator.canRescan || model.coordinator.snapshot == nil)

                Button {
                    model.stopScan()
                } label: {
                    Label("Stop Scan", systemImage: "stop.circle")
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.coordinator.isScanning)
            }

            CommandGroup(after: .textEditing) {
                Button {
                    model.search.requestFocus()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f")
                .disabled(model.coordinator.snapshot == nil)
            }

            CommandGroup(after: .sidebar) {
                Button {
                    withAnimation {
                        model.sidebarVisibility =
                            model.sidebarVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Label(
                        model.sidebarVisibility == .detailOnly
                            ? "Show Locations Sidebar"
                            : "Hide Locations Sidebar",
                        systemImage: "sidebar.left"
                    )
                }
                .keyboardShortcut("s", modifiers: [.control, .command])

                Button {
                    model.showKindStats.toggle()
                } label: {
                    Label(
                        model.showKindStats ? "Hide Statistics" : "Show Statistics",
                        systemImage: "sidebar.right"
                    )
                }
                .keyboardShortcut("k", modifiers: [.control, .command])
                .disabled(model.coordinator.snapshot == nil)
            }

            // No help book; the app is meant to be self-explanatory. Help
            // points at the GitHub repo instead.
            CommandGroup(replacing: .help) {
                Button {
                    NSWorkspace.shared.open(AppLinks.repository)
                } label: {
                    Label("Neodisk on GitHub", systemImage: "link")
                }

                Button {
                    NSWorkspace.shared.open(AppLinks.reportIssue)
                } label: {
                    Label("Report Issue…", systemImage: "flag")
                }
            }
        }

        Settings {
            SettingsView(model: model, preferences: preferences, updates: updates)
        }
    }
}
