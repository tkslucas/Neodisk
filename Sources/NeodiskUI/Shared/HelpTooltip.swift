// Tooltips through AppKit (`NSView.toolTip`) rather than SwiftUI's `.help`.
//
// On macOS 15, SwiftUI looks a tooltip up in its own list of views with `.help` when the pointer enters a view, and
// that list can still hold a view a click has just removed: entering and leaving a statistics drill-in with fast
// clicks crashed in `TooltipResponder.text` (F54). An AppKit tooltip belongs to its own NSView and goes away with it.
// Use `.neoHelp` for every tooltip in a view; `.help` stays only on menu items, where it becomes the item's toolTip.

import AppKit
import SwiftUI

extension View {
    /// A localized tooltip, as SwiftUI's `.help("…")`; interpolations work as in `Text`.
    func neoHelp(_ text: LocalizedStringResource) -> some View {
        neoHelp(verbatim: String(localized: text))
    }

    /// A tooltip shown as given (a path, a name, a string already localized), as `.help(someString)`.
    func neoHelp<S: StringProtocol>(_ text: S) -> some View {
        neoHelp(verbatim: String(text))
    }

    private func neoHelp(verbatim text: String) -> some View {
        background(HelpTooltipView(text: text))
            .accessibilityHint(Text(verbatim: text))
    }
}

/// Fills the view it backs and only carries the tooltip: clicks and hovers pass through to the SwiftUI content.
struct HelpTooltipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = HelpTooltipNSView()
        view.toolTip = text.isEmpty ? nil : text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let toolTip = text.isEmpty ? nil : text
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

final class HelpTooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
