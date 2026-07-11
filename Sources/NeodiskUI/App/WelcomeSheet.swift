//
//  WelcomeSheet.swift
//  Neodisk
//
//  First-launch onboarding: what the map is, the read-only guarantee, and
//  Full Disk Access status with instructions.
//

import AppKit
import SwiftUI

struct WelcomeSheet: View {
    let model: NeodiskViewModel

    @State private var accessStatus: FullDiskAccessStatus = .unknown

    // Packaged .apps get their own TCC entry (grant it to Neodisk itself);
    // unbundled `swift run` builds (no CFBundleIdentifier) inherit the
    // launching terminal's access, so step 2 differs.
    private var enableAccessSteps: String {
        Bundle.main.bundleIdentifier == nil
            ? "1. Open Privacy & Security → Full Disk Access.\n2. Turn it on for the app that launches Neodisk.\n3. Relaunch Neodisk."
            : "1. Open Privacy & Security → Full Disk Access.\n2. Turn it on for Neodisk.\n3. Choose Quit & Reopen when macOS asks."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("Welcome to Neodisk")
                    .font(.title.weight(.semibold))
                Text("Scan folders and disks to see where space is going.\nNeodisk is read-only: it never modifies or deletes files.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore the treemap").fontWeight(.semibold)
                    Text("Hover to inspect. Click to select. Pinch or scroll to move around. Double-click or right-click to Reveal in Finder. Switch between treemap and sunburst in the toolbar.")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "square.grid.3x3.topleft.filled").foregroundStyle(.blue)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read-only access").fontWeight(.semibold)
                    Text("Neodisk is purely a visualizer: it only ever reads your disk and cannot delete files or move them to the Trash — by design. To clean something up, right-click it, Reveal in Finder, and delete it there.")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.blue)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Full Disk Access").font(.headline)
                    Spacer()
                    switch accessStatus {
                    case .granted:
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .notGranted:
                        Label("Not enabled", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.orange)
                    case .unknown:
                        Label("Checking…", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                if accessStatus == .granted {
                    Text("Neodisk can read protected locations. You can start a complete scan now.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Without it, protected locations (Mail, Safari, Messages, parts of Library) are skipped and totals are underreported. To enable:")
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey(enableAccessSteps))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Open Full Disk Access Settings") {
                        _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
                    }
                    Button("Recheck") { recheck() }
                }
            }

            HStack {
                Spacer()
                Button("Continue") {
                    model.dismissWelcome()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(ModalTerminationBehavior())
        .task { recheck() }
    }

    private func recheck() {
        accessStatus = .unknown
        Task {
            let status = await Task.detached(priority: .utility) {
                SystemIntegration.fullDiskAccessStatus()
            }.value
            accessStatus = status
        }
    }
}

// Granting Full Disk Access makes macOS offer "Quit & Reopen", which sends a
// polite terminate. A sheet window blocks that by default
// (preventsApplicationTerminationWhenModal), so the app silently refuses to
// quit while this welcome sheet is up. Opt the sheet out so the relaunch works.
private struct ModalTerminationBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(for: nsView)
    }

    private func updateWindow(for view: NSView) {
        DispatchQueue.main.async {
            view.window?.preventsApplicationTerminationWhenModal = false
        }
    }
}
