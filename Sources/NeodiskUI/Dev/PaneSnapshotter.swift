// Panes rendered alone once the scan settles, for states the window capture can't show (the split view's sidebar
// material takes its content with it). Inert unless their variable is set:
// - NEODISK_SIDEBAR_SNAPSHOT=<out.png>: the sidebar (NEODISK_SIDEBAR_SNAPSHOT_WIDTH, default 260 × text scale).
// - NEODISK_TABBAR_SNAPSHOT=<out.png>: the statistics tab bar at several widths, stacked.
// - NEODISK_STATS_SNAPSHOT=<out.png>: the statistics pane on its NEODISK_ANALYSIS_TAB (NEODISK_STATS_SNAPSHOT_WIDTH,
//   default 230, the pane's default; the window capture uses the stored width instead).
// - NEODISK_WELCOME_SNAPSHOT=<out.png>: the welcome sheet at its own width.
// All read NEODISK_SNAPSHOT_APPEARANCE=light and NEODISK_SNAPSHOT_TEXT_SCALE=<0.85…2>.

import AppKit
import SwiftUI

@MainActor
enum PaneSnapshotter {
    static func scheduleIfRequested(model: NeodiskViewModel) {
        let environment = ProcessInfo.processInfo.environment
        let sidebarPath = environment["NEODISK_SIDEBAR_SNAPSHOT"]
        let tabBarPath = environment["NEODISK_TABBAR_SNAPSHOT"]
        let statsPath = environment["NEODISK_STATS_SNAPSHOT"]
        let welcomePath = environment["NEODISK_WELCOME_SNAPSHOT"]
        guard sidebarPath != nil || tabBarPath != nil || statsPath != nil || welcomePath != nil else { return }
        let scale = environment["NEODISK_SNAPSHOT_TEXT_SCALE"].flatMap(Double.init).map(TextScale.snapped) ?? 1
        let dark = environment["NEODISK_SNAPSHOT_APPEARANCE"] != "light"
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                if !model.coordinator.isScanning, model.coordinator.snapshot?.isComplete == true { break }
            }
            try? await Task.sleep(for: .seconds(3))
            if let sidebarPath {
                // The real column's width scales with the text.
                let width = environment["NEODISK_SIDEBAR_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 260 * scale
                await render(
                    SidebarPane(model: model), size: CGSize(width: width, height: 760),
                    scale: scale, dark: dark, to: sidebarPath
                )
            }
            if let statsPath {
                let width = environment["NEODISK_STATS_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 230
                await render(
                    AnalysisPane(model: model), size: CGSize(width: width * scale, height: 640 * scale),
                    scale: scale, dark: dark, to: statsPath
                )
            }
            if let welcomePath {
                // Taller than the sheet; it sits at the top, so a cut line shows as one.
                await render(
                    WelcomeSheet(model: model), size: CGSize(width: 460, height: 820),
                    scale: 1, dark: dark, to: welcomePath
                )
            }
            if let tabBarPath {
                let widths: [CGFloat] = [140, 180, 220, 260, 300, 360, 440]
                let bars = VStack(alignment: .leading, spacing: 0) {
                    ForEach(widths, id: \.self) { width in
                        AnalysisTabBar(model: model).frame(width: width * scale)
                        Divider()
                    }
                }
                await render(
                    bars, size: CGSize(width: 440 * scale, height: CGFloat(widths.count * 34) * scale),
                    scale: scale, dark: dark, to: tabBarPath
                )
            }
        }
    }

    private static func render(
        _ view: some View, size: CGSize, scale: Double, dark: Bool, to path: String
    ) async {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.alphaValue = 0
        let host = NSHostingView(rootView: view
            .environment(\.neoTextScale, scale)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
        FileHandle.standardError.write(Data("NEODISK_PANE_SNAPSHOT: wrote \(path)\n".utf8))
        window.orderOut(nil)
    }
}
