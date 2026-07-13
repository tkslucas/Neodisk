//
//  DebugSnapshotter.swift
//  Neodisk
//
//  Dev/testing hook: NEODISK_UI_SNAPSHOT=<out.png> waits for a scan, zooms
//  the map programmatically, and writes a capture of the whole window so
//  clipping and layer orientation can be verified headlessly. Lives outside
//  TreemapNSView so the shipping view class stays about rendering.
//

import AppKit
import SwiftUI

/// Keeps the host window off Lucas's screen while a headless snapshot runs:
/// moves it far offscreen and makes it transparent as soon as it is attached
/// to a window, so `NEODISK_UI_SNAPSHOT` captures (via `cacheDisplay`, which
/// reads the layer tree regardless of on-screen visibility) without the window
/// ever appearing or stealing focus. Inert unless the env var is set.
struct SnapshotWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] != nil else {
            return view
        }
        // Poll for the window instead of relying on updateNSView: SwiftUI
        // does not re-call updateNSView on window attachment, so a quiet
        // view hierarchy (sunburst mode) never saw a non-nil window there.
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
        guard ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] != nil,
              let window = view.window else { return }
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

    /// Plain window capture for runs where no treemap view ever attaches
    /// (NEODISK_VIZ_MODE=sunburst): waits out the scan, then defers to the
    /// treemap path if one registered in the meantime.
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
        // Capture the window's frame view (superview of the content view) so
        // the titlebar and toolbar are included — the content view alone omits
        // the toolbar, which some snapshots need to verify (e.g. the update
        // pill). Falls back to the content view if the frame view is absent.
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
