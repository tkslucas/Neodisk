// The menu bar commands, extracted from NeodiskApp so the scene body
// stays small.

import AppKit
import SwiftUI
import NeodiskKit
import NeodiskAppModel
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
            AddFolderMenuItem(model: model)

            Group {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(!model.canRescan)

                Button {
                    model.stopScan()
                } label: {
                    Label("Stop Scan", systemImage: "stop.circle")
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.coordinator.isScanning)
            }
            .disabled(!model.isWindowOpen)
        }

        CommandGroup(after: .pasteboard) {
            Group {
                // Beside Select All, where every Mac app keeps it.
                Button {
                    model.select(nil)
                } label: {
                    Label("Deselect All", systemImage: "clear")
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model.selection.isEmpty)
            }
            .disabled(!model.isWindowOpen)
        }

        CommandGroup(after: .textEditing) {
            Group {
                Button {
                    model.search.requestFocus()
                } label: {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f")
                .disabled(model.coordinator.snapshot == nil)
            }
            .disabled(!model.isWindowOpen)
        }

        CommandGroup(after: .sidebar) {
            Group {
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

                // Where sections hidden from a header's menu come back.
                Menu("Sidebar Sections") {
                    SidebarSectionsMenuItems(model: model)
                }
                // Its sections can't change visibly while the sidebar is hidden.
                .disabled(model.sidebarVisibility == .detailOnly)

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

                // Where tabs hidden from the statistics bar's menu come back.
                Menu("Statistics Tabs") {
                    AnalysisTabsMenuItems(model: model)
                }

                Divider()

                // Disabled at the ends rather than silently inert. Like browser zoom, it leaves menus and Settings
                // alone.
                Button {
                    model.zoomTextIn()
                } label: {
                    Label("Zoom In", systemImage: "textformat.size.larger")
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canZoomTextIn)

                Button {
                    model.zoomTextOut()
                } label: {
                    Label("Zoom Out", systemImage: "textformat.size.smaller")
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canZoomTextOut)

                Button {
                    model.resetTextSize()
                } label: {
                    Label("Actual Size", systemImage: "textformat.size")
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model.isTextSizeStandard)

                Divider()

                // Hidden views stay here as the way back: picking one shows it in the toolbar again.
                // The current view is checked, as the file list placements below are.
                ForEach(Array(VizView.allCases.enumerated()), id: \.element) { index, view in
                    Toggle(isOn: Binding(
                        get: { model.coordinator.snapshot != nil && model.vizView == view },
                        set: { _ in model.updateLayout { $0.pick(view) } }
                    )) {
                        Label(view.menuTitle, systemImage: view.systemImage)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    .disabled(model.coordinator.snapshot == nil)
                }

                Divider()

                Button {
                    model.updateLayout { $0.setListShown(!$0.showsList) }
                } label: {
                    Label(model.layout.showsList ? "Hide File List" : "Show File List", systemImage: "list.bullet.indent")
                }
                .disabled(model.coordinator.snapshot == nil)

                ForEach(OutlinePosition.menuOrder, id: \.self) { position in
                    Toggle(isOn: Binding(
                        get: { model.layout.showsList(at: position) },
                        set: { _ in model.updateLayout { $0.placeList(position) } }
                    )) {
                        Label(position.menuTitle, systemImage: position.systemImage)
                    }
                    .disabled(model.coordinator.snapshot == nil || !model.layout.canPlaceList(position))
                }

                // The way back for columns hidden from the table header's menu.
                Menu("File List Columns") {
                    ForEach(model.outlineColumns.order.filter { $0 != .name }, id: \.self) { column in
                        Toggle(column.menuTitle, isOn: Binding(
                            get: { !model.outlineColumns.isHidden(column) },
                            set: { isShown in
                                var layout = model.outlineColumns
                                layout.setHidden(column, !isShown)
                                model.setOutlineColumns(layout)
                            }
                        ))
                        .disabled(!model.outlineColumns.isHidden(column) && !model.outlineColumns.canHide(column))
                    }
                }
                // Columns belong to the bottom table: nothing to see while it isn't showing.
                .disabled(model.coordinator.snapshot == nil || !model.layout.showsBottomList)

                Divider()

                Button {
                    model.setStatusBarShown(!model.showsStatusBar)
                } label: {
                    Label(model.showsStatusBar ? "Hide Status Bar" : "Show Status Bar", systemImage: "info.square")
                }
                .keyboardShortcut("/", modifiers: .command)
                // The status bar shows only with a scan on screen.
                .disabled(model.coordinator.snapshot == nil)
            }
            .disabled(!model.isWindowOpen)
        }

        // The visualization key handlers own these shortcuts too; the menu intercepts first and calls the same
        // actions, and works without the visualization focused.
        CommandMenu("Go") {
            Group {
                Button {
                    beepUnless(model.drillBack())
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .keyboardShortcut("[")
                .disabled(!model.drillHistory.canGoBack)

                Button {
                    beepUnless(model.drillForward())
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .keyboardShortcut("]")
                .disabled(!model.drillHistory.canGoForward)

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
                .disabled(!model.canDrillIntoSelection)

                Divider()

                Button {
                    model.zoomToRoot()
                } label: {
                    Label("Back to Scan Root", systemImage: "arrowshape.turn.up.backward")
                }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                .disabled(!model.canDrillOut)
            }
            .disabled(!model.isWindowOpen)
        }

        CommandMenu("Inspect") {
            Group {
                Button {
                    model.quickLookSelection()
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .keyboardShortcut("y")
                .disabled(model.selection.isEmpty)

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
                    Label(LocalizedStringKey(model.selection.isMultiple ? "Copy Paths" : "Copy Path"), systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!model.selectionSupportsFileActions)

                if model.cleanup.isEnabled {
                    Divider()

                    Button {
                        model.toggleCleanupForSelection()
                    } label: {
                        Label(model.cleanupMenuTitle(for: model.selectedNodes), systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    // Refused items stay enabled: ⌘⌫ then says why. Something inside a collected folder is already in.
                    .disabled(model.cleanup.toggle(for: model.selectedNodes) == .none)

                    Button {
                        model.cleanup.moveAllToTrash()
                    } label: {
                        Label("Move Cleanup to Trash…", systemImage: "trash.fill")
                    }
                    .disabled(!model.cleanup.canMoveToTrash)
                }
            }
            .disabled(!model.isWindowOpen)
        }

        // The way back to the main window once it's closed, as the Dock icon is; SwiftUI doesn't list a primary
        // Window scene itself. No ⌘0: it's Actual Size here.
        CommandGroup(before: .windowArrangement) {
            MainWindowMenuItem()
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
                DiagnosticsExport.run()
            } label: {
                Label("Export Diagnostics…", systemImage: "stethoscope")
            }

            Divider()

            Button {
                NSWorkspace.shared.open(AppLinks.sponsor)
            } label: {
                Label("Support Neodisk…", systemImage: "heart")
            }
        }
    }
}

/// Add Folder… works with the main window closed too: it brings the window back first, so the panel opens as its
/// sheet and the scan shows.
private struct AddFolderMenuItem: View {
    let model: NeodiskViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if model.isWindowOpen {
                model.chooseFolderAndScan()
            } else {
                openWindow(id: NeodiskApp.mainWindowID)
                // The window orders front on the next pass of the run loop; the panel then finds it.
                DispatchQueue.main.async { model.chooseFolderAndScan() }
            }
        } label: {
            Label("Add Folder…", systemImage: "folder.badge.plus")
        }
        .keyboardShortcut("o")
    }
}

private struct MainWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AppChannel.current.appName) { openWindow(id: NeodiskApp.mainWindowID) }
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
            Label("About \(AppChannel.current.appName)", systemImage: "info.circle")
        }
    }
}
