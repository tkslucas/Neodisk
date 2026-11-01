import AppKit
import SwiftUI
import NeodiskKit

public struct NeodiskApp: App {
    @State private var model: NeodiskViewModel
    @StateObject private var preferences: AppPreferences
    // Sparkle auto-updates; inert (no updater) for unbundled `swift run`
    // builds and bundles without an appcast feed. See UpdateController.
    @StateObject private var updates = UpdateController()
    @NSApplicationDelegateAdaptor private var quitDelegate: QuitDelegate
    private let snapshotCache = ScanSnapshotCache()

    public init() {
        FeltTiming.markLaunch("appInit")
        DiagnosticsMonitor.start()
        let model = NeodiskViewModel(
            coordinator: ScanCoordinator(scanService: IncrementalScanService()),
            snapshotCache: snapshotCache
        )
        // Bound before the first frame: binding on appear drew one frame at 100% text size, and a control focused
        // there kept its 100% focus ring on macOS 26.
        let preferences = AppPreferences()
        model.preferences = preferences
        _model = State(initialValue: model)
        _preferences = StateObject(wrappedValue: preferences)
        FeltTiming.markLaunch("modelReady")

        // Single-window app: no window tabs, so the View menu loses the
        // useless "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false

        // `swift run` has no bundle: become a regular app with a menu bar, unless headless (a capture or bench run),
        // which stays an accessory that never activates or shows on screen (see HeadlessMode).
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
                .onAppear {
                    preferences.applyTheme()
                    quitDelegate.snapshotCache = snapshotCache
                }
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
        // About opens from the app menu only, not as a Window menu item.
        .commandsRemoved()
    }
}

/// Quitting waits briefly for snapshot saves still encoding, so the scan that just finished opens next launch.
@MainActor
final class QuitDelegate: NSObject, NSApplicationDelegate {
    var snapshotCache: ScanSnapshotCache?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let snapshotCache else { return .terminateNow }
        sender.windows.forEach { $0.orderOut(nil) }
        Task.detached {
            await snapshotCache.finishSaves(within: .seconds(10))
            // The main actor doesn't run while a quit is pending; the modal-panel run loop does.
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}
