// macOS 15 workaround: toolbar buttons that keep a stale look.
//
// On macOS 15, SwiftUI draws a toolbar button as an AppKit button hosting the SwiftUI label, and the label only
// takes the button's enabled and active-window state when AppKit sets `isEnabled` on it (or the pointer passes over
// it). SwiftUI's own updates and the window's key changes don't reach it, so a button enabled while the window was
// inactive, or anything redrawn by a theme change made in Settings, stayed drawn in the disabled gray once the window
// was key again (F49). Setting `isEnabled` again after those changes redraws the labels with the real state.
// macOS 26 draws toolbar buttons differently and doesn't need it.

import AppKit
import SwiftUI

/// Placed in the window's content; `state` is everything the toolbar buttons' enabled state depends on.
struct ToolbarButtonRefresher<State: Equatable>: NSViewRepresentable {
    let state: State

    func makeNSView(context: Context) -> ToolbarButtonRefresherView {
        ToolbarButtonRefresherView()
    }

    func updateNSView(_ view: ToolbarButtonRefresherView, context: Context) {
        guard view.lastState as? State != state else { return }
        view.lastState = state
        view.refreshSoon()
    }
}

final class ToolbarButtonRefresherView: NSView {
    var lastState: Any?
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            }
        }
        refreshSoon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSoon()
    }

    /// After the current pass, so SwiftUI has applied its update and AppKit its key change.
    func refreshSoon() {
        if #available(macOS 26.0, *) { return }
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            guard let view = item.view else { continue }
            for button in Self.buttons(in: view) {
                let isEnabled = button.isEnabled
                button.isEnabled = !isEnabled
                button.isEnabled = isEnabled
            }
        }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap(buttons(in:))
    }
}
