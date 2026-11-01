// The line under the content: what's hovered or selected (its color in the map, name, size and path), or
// the scan's totals, and how many files couldn't be read.

import CNeodiskWin
import Foundation
import WinSDK

@MainActor
final class StatusBarView: SurfaceView {
    struct State: Equatable {
        var swatch: RGBA?
        var name = ""
        var detail = ""
        var warning = ""
        var warningTooltip = ""
    }

    var state = State() {
        didSet {
            guard state != oldValue else { return }
            invalidate()
            refreshAccessibility()
            announceValueChange(Self.textID)
        }
    }

    static let height: Double = 32
    private static let textID: Int32 = 1
    private static let warningID: Int32 = 2

    init(parent: HWND) {
        super.init(parent: parent, role: NDW_ROLE_STATUS_BAR, name: L("Status"))
    }

    private var warningFrame: CGRect {
        guard !state.warning.isEmpty else { return .zero }
        let width = Gfx.textWidth(state.warning, style: .caption) + 24
        return CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    override func elements() -> [Element] {
        var text = state.name
        if !state.detail.isEmpty { text += ", " + state.detail }
        var result = [Element(id: Self.textID, role: NDW_ROLE_TEXT, name: text, frame: bounds, interactive: false)]
        if !state.warning.isEmpty {
            result.append(Element(id: Self.warningID, role: NDW_ROLE_TEXT, name: state.warning,
                                  help: state.warningTooltip, frame: warningFrame, interactive: false))
        }
        return result
    }

    override func draw(_ g: Gfx) {
        let theme = self.theme
        let bounds = self.bounds
        g.fill(bounds, theme.layer)
        g.hairline(x0: 0, y0: 0, x1: bounds.width, y1: 0, theme.divider)
        var x = 0.0
        if let swatch = state.swatch {
            g.fill(CGRect(x: x, y: bounds.midY - 5, width: 10, height: 10), swatch, radius: 2)
            x += 18
        }
        let warning = warningFrame
        let textEnd = state.warning.isEmpty ? bounds.width : warning.minX - 8
        let nameWidth = min(Gfx.textWidth(state.name, style: .bodyStrong) + 1, max(0, textEnd - x) * 0.6)
        g.text(state.name, in: CGRect(x: x, y: 0, width: nameWidth, height: bounds.height), style: .bodyStrong,
               color: theme.textPrimary)
        x += nameWidth + 12
        g.text(state.detail, in: CGRect(x: x, y: 0, width: max(0, textEnd - x), height: bounds.height),
               style: .captionNumeric, color: theme.textSecondary)
        if !state.warning.isEmpty {
            g.icon(.warning, in: CGRect(x: warning.minX, y: 0, width: 16, height: bounds.height), size: 12, color: theme.caution)
            g.text(state.warning, in: CGRect(x: warning.minX + 20, y: 0, width: warning.width - 20, height: bounds.height),
                   style: .caption, color: theme.caution)
        }
    }
}
