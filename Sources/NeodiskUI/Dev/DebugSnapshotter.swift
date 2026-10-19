// Dev hook: NEODISK_UI_SNAPSHOT=<out.png> waits for a scan, zooms the map and captures the window headlessly.

import AppKit
import SwiftUI

/// Moves the window offscreen and transparent once attached; `cacheDisplay` reads the layer tree anyway,
/// so it captures without the window appearing or stealing focus. Inert unless the env var is set.
struct SnapshotWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard HeadlessMode.isOffscreen else {
            return view
        }
        // Poll: SwiftUI doesn't re-call updateNSView on window attachment, so a quiet hierarchy never saw the
        // window.
        Task { @MainActor [weak view] in
            for _ in 0..<200 {
                if let view, let window = view.window {
                    Self.hide(window)
                    // Visualizations without a dedicated capture path (the
                    // sunburst) still get a plain window capture.
                    DebugSnapshotter.shared.scheduleWindowFallback(for: view)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard HeadlessMode.isOffscreen, let window = view.window else { return }
        Self.hide(window)
    }

    private static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
    }
}

@MainActor
final class DebugSnapshotter {
    static let shared = DebugSnapshotter()

    private var scheduled = false
    private var fallbackScheduled = false

    func scheduleIfRequested(for view: TreemapNSView) {
        guard view.window != nil, !scheduled,
              let path = ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] else {
            return
        }
        scheduled = true
        Self.log("scheduled windowNumber=\(view.window?.windowNumber ?? -1)")
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(6))
            guard let view else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            view.controller.magnify(by: 3, anchor: center)
            _ = view.controller.scroll(by: CGSize(width: -view.bounds.width, height: 0))
            try? await Task.sleep(for: .seconds(2))
            Self.writeWindowSnapshot(of: view, to: path)
        }
    }

    /// For runs where no treemap view attaches (NEODISK_VIZ_MODE=sunburst).
    func scheduleWindowFallback(for view: NSView) {
        guard view.window != nil, !fallbackScheduled, !scheduled,
              let path = ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] else {
            return
        }
        fallbackScheduled = true
        Self.log("fallback scheduled windowNumber=\(view.window?.windowNumber ?? -1)")
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !self.scheduled, let view else { return }
            Self.writeWindowSnapshot(of: view, to: path)
        }
    }

    private static func writeWindowSnapshot(of view: NSView, to path: String) {
        // The frame view includes the titlebar and toolbar, which the content view omits (e.g. the update
        // pill).
        guard let contentView = view.window?.contentView else {
            log("no content view to capture")
            return
        }
        let target = contentView.superview ?? contentView
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            log("no bitmap rep to capture")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log("PNG encoding failed")
            return
        }
        do {
            try data.write(to: URL(filePath: path))
            log("wrote \(path)")
        } catch {
            log("\(error)")
        }
    }

    /// Unbuffered, so scripts driving the hook can read it while the app runs.
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("NEODISK_UI_SNAPSHOT: \(message)\n".utf8))
    }
}
