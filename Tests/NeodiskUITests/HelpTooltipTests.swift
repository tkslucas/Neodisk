import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NeodiskUI

/// F54: SwiftUI's `.help` crashed on macOS 15 when the pointer entered a view in the moment a click removed one
/// with `.help` (statistics drill-ins). Tooltips go through AppKit (`.neoHelp`), which removes them with their view.
@MainActor
@Suite(.serialized) struct HelpTooltipTests {
    private final class Visibility: ObservableObject {
        @Published var shown = true
    }

    private struct Rows: View {
        @ObservedObject var visibility: Visibility

        var body: some View {
            VStack {
                if visibility.shown {
                    Text(verbatim: "Other").neoHelp("Show every file of this kind")
                }
                Text(verbatim: "/Applications/Xcode.app").neoHelp("/Applications/Xcode.app")
            }
            .frame(width: 240, height: 120)
        }
    }

    private func tooltips(in view: NSView) -> [String] {
        let own = (view as? HelpTooltipNSView)?.toolTip.map { [$0] } ?? []
        return own + view.subviews.flatMap(tooltips(in:))
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }

    @Test func tooltipsAreAppKitsAndLeaveWithTheirView() {
        let visibility = Visibility()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: .borderless, backing: .buffered, defer: true
        )
        let host = NSHostingView(rootView: Rows(visibility: visibility))
        window.contentView = host
        settle(host)
        #expect(Set(tooltips(in: host)) == ["Show every file of this kind", "/Applications/Xcode.app"])
        // Clicks and hovers reach the SwiftUI content, never the tooltip's view.
        let tipView = host.subviewsRecursive.first { $0 is HelpTooltipNSView }
        #expect(tipView?.hitTest(NSPoint(x: 1, y: 1)) == nil)

        visibility.shown = false
        settle(host)
        #expect(tooltips(in: host) == ["/Applications/Xcode.app"])
    }

    /// `.help` stays only on menu items (where it becomes the NSMenuItem's toolTip); every view uses `.neoHelp`.
    @Test func viewsUseAppKitTooltipsNotSwiftUIHelp() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NeodiskUI")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains(".help(") && !line.contains("a menu item") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "use .neoHelp (SwiftUI's .help crashes on macOS 15, F54): \(offenders)")
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] { subviews + subviews.flatMap(\.subviewsRecursive) }
}
