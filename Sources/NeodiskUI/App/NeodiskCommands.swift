//
//  NeodiskCommands.swift
//  Neodisk
//
//  The menu bar commands, extracted from NeodiskApp so the scene body
//  stays small.
//

import AppKit
import SwiftUI
import TreemapKit

struct NeodiskCommands: Commands {
    let model: NeodiskViewModel
    @ObservedObject var updates: UpdateController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutMenuItem()
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

            Divider()

            // The three center views, mirroring the toolbar picker (same
            // two-preference write: a treemap item sets both, Sunburst keeps
            // the treemap style for the trip back).
            Button {
                model.preferences?.vizViewMode = .treemap
                model.preferences?.treemapStyle = .cushion
            } label: {
                Label("Cushion Treemap", systemImage: "square.split.bottomrightquarter")
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(model.coordinator.snapshot == nil)

            Button {
                model.preferences?.vizViewMode = .treemap
                model.preferences?.treemapStyle = .flat
            } label: {
                Label("Flat Treemap", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(model.coordinator.snapshot == nil)

            Button {
                model.preferences?.vizViewMode = .sunburst
            } label: {
                Label("Sunburst", systemImage: "chart.pie")
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(model.coordinator.snapshot == nil)

            Divider()

            // Same preference as the Settings picker; the menu adds
            // discoverability and a checkmark for the current state. This
            // treemap position stays independent of Sunburst's opt-in below.
            Toggle(isOn: Binding(
                get: { model.outlinePosition == .bottom },
                set: { model.preferences?.outlinePosition = $0 ? .bottom : .leading }
            )) {
                Label("File List Below Treemap", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .disabled(model.coordinator.snapshot == nil)

            Toggle(isOn: Binding(
                get: { model.showsFileListBelowSunburst },
                set: { model.preferences?.showFileListBelowSunburst = $0 }
            )) {
                Label(
                    "Show File List Below Sunburst",
                    systemImage: "rectangle.bottomthird.inset.filled"
                )
            }
            .disabled(model.coordinator.snapshot == nil)
        }

        // Finder-style Go menu for the drill and selection axes. The same
        // shortcuts also live in the treemap/sunburst key handlers; the menu
        // intercepts them first and calls the same model actions, so behavior
        // matches — the menu just adds discoverability and works without the
        // visualization focused.
        CommandMenu("Go") {
            Button {
                beepUnless(model.drillOut())
            } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
            }
            .keyboardShortcut(.upArrow)
            .disabled(!model.canDrillOut)

            Button {
                beepUnless(model.drillIntoSelection())
            } label: {
                Label("Zoom Into Selection", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut(.downArrow)
            .disabled(model.selectedNode == nil)

            Divider()

            Button {
                model.zoomToRoot()
            } label: {
                Label("Back to Scan Root", systemImage: "arrowshape.turn.up.backward")
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            .disabled(!model.canDrillOut)

            Divider()

            Button {
                model.select(nil)
            } label: {
                Label("Deselect", systemImage: "clear")
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(model.selectedNodeID == nil)
        }

        // File actions for the selection — the context menus' items, made
        // discoverable with shortcuts. No Move to Trash: Neodisk is read-only
        // by design.
        CommandMenu("Inspect") {
            Button {
                model.quickLookSelection()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .keyboardShortcut("y")
            .disabled(model.selectedNode == nil)

            Divider()

            Button {
                model.openSelection()
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!model.selectionSupportsFileActions)

            Button {
                model.revealSelection()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!model.selectionSupportsFileActions)

            Button {
                model.copyPathOfSelection()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!model.selectionSupportsFileActions)
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

            Button {
                NSWorkspace.shared.open(AppLinks.sponsor)
            } label: {
                Label("Support Neodisk…", systemImage: "heart")
            }
        }
    }
}

/// The About menu item needs `openWindow`, which is only available through
/// the SwiftUI environment — hence a view instead of an inline Button.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "about")
        } label: {
            Label("About Neodisk", systemImage: "info.circle")
        }
    }
}
