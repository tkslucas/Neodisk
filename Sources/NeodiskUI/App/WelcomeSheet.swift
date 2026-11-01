// First-launch onboarding: what the map is, how Cleanup keeps removal safe, and
// Full Disk Access status with instructions.

import AppKit
import SwiftUI

struct WelcomeSheet: View {
    let model: NeodiskViewModel

    @State private var accessStatus: FullDiskAccessStatus = .unknown
    @Environment(\.neoTextScale) private var textScale

    // Unbundled `swift run` builds inherit the launching terminal's access, so step 2 differs from packaged
    // apps.
    private var enableAccessSteps: String {
        Bundle.main.bundleIdentifier == nil
            ? "1. Open Privacy & Security → Full Disk Access.\n2. Turn it on for the app that launches Neodisk.\n3. Relaunch Neodisk."
            : "1. Open Privacy & Security → Full Disk Access.\n2. Turn it on for Neodisk.\n3. Choose Quit & Reopen when macOS asks."
    }

    var body: some View {
        // Scrolls only where large text makes it taller than the screen; otherwise it sizes to its content.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: (460 * textScale).rounded())
        .frame(maxHeight: maxHeight)
        .background(ModalTerminationBehavior())
        .task { recheck() }
    }

    /// The screen's height less room for the title bar the sheet hangs from.
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 120
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16 * textScale) {
            VStack(spacing: 8 * textScale) {
                Image(systemName: "internaldrive.fill")
                    .neoFont(44)
                    .foregroundStyle(.blue)
                Text("Welcome to Neodisk")
                    .neoFont(.title)
                    .fontWeight(.semibold)
                Text("Scan folders and disks to see where space is going,\nthen clear out what you don't need.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    // Every wrapping line takes its full height: a sheet sizes to its ideal height, which cut the
                    // last line.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore the treemap").fontWeight(.semibold)
                    Text("Hover to inspect. Click to select. Pinch or scroll to move around. Double-click or right-click to Reveal in Finder. Switch between treemap and sunburst in the toolbar.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "square.grid.3x3.topleft.filled").foregroundStyle(.blue)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up safely").fontWeight(.semibold)
                    Text("Drag items to Cleanup at the bottom of the sidebar, or press ⌘⌫. Nothing moves until you confirm, items go to the Trash so you can still get them back, and system folders are off-limits. You can turn this off in Settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "trash").foregroundStyle(.blue)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8 * textScale) {
                HStack {
                    Text("Full Disk Access").neoFont(.headline)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if accessStatus == .granted {
                    Text("Neodisk can read protected locations. You can start a complete scan now.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Without it, protected locations (Mail, Safari, Messages, parts of Library) are skipped and totals are underreported. To enable:")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedStringKey(enableAccessSteps))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
                    } label: {
                        Text("Open Full Disk Access Settings").neoFont(.body)
                    }
                    Button { recheck() } label: { Text("Recheck").neoFont(.body) }
                }
            }

            HStack {
                Spacer()
                Button {
                    model.dismissWelcome()
                } label: {
                    Text("Continue").neoFont(.body)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        // Its buttons and text follow the workspace text size: the sheet belongs to the window.
        .neoFont(.body)
        .neoControlSize()
        .padding(24 * textScale)
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

// Granting Full Disk Access offers "Quit & Reopen", but a sheet blocks termination by default
// (preventsApplicationTerminationWhenModal), so opt this one out or the relaunch silently fails.
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
