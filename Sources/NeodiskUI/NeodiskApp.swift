//
//  NeodiskApp.swift
//  Neodisk
//

import AppKit
import SwiftUI

public struct NeodiskApp: App {
    @State private var model = NeodiskViewModel()
    @StateObject private var preferences = AppPreferences()

    public init() {
        // Single-window app: no window tabs, so the View menu loses the
        // useless "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Running via `swift run` there is no app bundle, so opt into being a
        // regular foreground app with a menu bar and key window.
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
        }
    }

    public var body: some Scene {
        WindowGroup {
            ContentView(model: model, preferences: preferences)
                .onAppear { preferences.applyTheme() }
        }
        .commands {
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
        }

        Settings {
            SettingsView(model: model, preferences: preferences)
        }
    }
}
