// NEODISK_SIDEBAR_SNAPSHOT=<out.png>: renders the sidebar alone once the scan settles. The window capture can't
// draw it: the split view's sidebar material takes its content with it.

import AppKit
import SwiftUI

@MainActor
enum SidebarSnapshotter {
    static func scheduleIfRequested(model: NeodiskViewModel) {
        guard let path = ProcessInfo.processInfo.environment["NEODISK_SIDEBAR_SNAPSHOT"] else { return }
        let dark = ProcessInfo.processInfo.environment["NEODISK_SNAPSHOT_APPEARANCE"] != "light"
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                if !model.coordinator.isScanning, model.coordinator.snapshot?.isComplete == true { break }
            }
            try? await Task.sleep(for: .seconds(3))
            let size = CGSize(width: 260, height: 760)
            let window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.alphaValue = 0
            let host = NSHostingView(rootView: SidebarPane(model: model)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            FileHandle.standardError.write(Data("NEODISK_SIDEBAR_SNAPSHOT: wrote \(path)\n".utf8))
            window.orderOut(nil)
        }
    }
}
