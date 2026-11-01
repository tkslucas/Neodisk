// What the content layer shows before there's a scan to show: an invitation to pick a location, or the
// note that a saved scan is opening.

import CNeodiskWin
import Foundation
import WinSDK

@MainActor
final class EmptyStateView: SurfaceView {
    struct State: Equatable {
        var title = ""
        var message = ""
        var showsButton = true
    }

    var state = State() {
        didSet {
            guard state != oldValue else { return }
            invalidate()
            refreshAccessibility()
        }
    }
    var onChooseFolder: (() -> Void)?

    private static let titleID: Int32 = 1
    private static let messageID: Int32 = 2
    private static let buttonID: Int32 = 3

    init(parent: HWND) {
        super.init(parent: parent, role: NDW_ROLE_PANE, name: "")
    }

    private var lines: [String] { state.message.components(separatedBy: "\n") }

    private var frames: (icon: CGRect, title: CGRect, message: CGRect, button: CGRect) {
        let bounds = self.bounds
        let messageHeight = Double(lines.count) * 20
        let buttonHeight = state.showsButton ? 32.0 + 24 : 0
        let total = 56 + 16 + 28 + 8 + messageHeight + buttonHeight
        var y = max(0, (bounds.height - total) / 2)
        let icon = CGRect(x: bounds.midX - 28, y: y, width: 56, height: 56)
        y += 56 + 16
        let title = CGRect(x: 0, y: y, width: bounds.width, height: 28)
        y += 28 + 8
        let message = CGRect(x: 0, y: y, width: bounds.width, height: messageHeight)
        y += messageHeight + 24
        let label = L("Choose Folder…")
        let buttonWidth = Gfx.textWidth(label) + 40
        let button = state.showsButton
            ? CGRect(x: bounds.midX - buttonWidth / 2, y: y, width: buttonWidth, height: 32) : .zero
        return (icon, title, message, button)
    }

    override func elements() -> [Element] {
        let frames = self.frames
        var result = [
            Element(id: Self.titleID, role: NDW_ROLE_TEXT, name: state.title, frame: frames.title, interactive: false),
            Element(id: Self.messageID, role: NDW_ROLE_TEXT, name: lines.joined(separator: " "), frame: frames.message,
                    interactive: false),
        ]
        if state.showsButton {
            result.append(Element(id: Self.buttonID, role: NDW_ROLE_BUTTON, name: L("Choose Folder…"), help: "Ctrl+O",
                                  automationID: "emptyChooseFolder", frame: frames.button, focusable: true))
        }
        return result
    }

    override func activate(_ id: Int32, fromKeyboard: Bool) {
        if id == Self.buttonID { onChooseFolder?() }
    }

    override func draw(_ g: Gfx) {
        let theme = self.theme
        let frames = self.frames
        g.fill(bounds, theme.layer)
        g.icon(state.showsButton ? .hardDrive : .refresh, in: frames.icon, size: 48, color: theme.textTertiary)
        g.text(state.title, in: frames.title, style: TextStyle.subtitle.aligned(NDW_ALIGN_CENTER), color: theme.textPrimary)
        for (index, line) in lines.enumerated() {
            g.text(line, in: CGRect(x: frames.message.minX, y: frames.message.minY + Double(index) * 20,
                                    width: frames.message.width, height: 20),
                   style: TextStyle.body.aligned(NDW_ALIGN_CENTER), color: theme.textSecondary)
        }
        guard state.showsButton else { return }
        let button = frames.button
        let hovered = hoveredID == Self.buttonID
        let pressed = hovered && pressedID == Self.buttonID
        let fill = pressed ? theme.accentFill.withAlpha(0.8) : hovered ? theme.accentFillHover : theme.accentFill
        g.fill(button, fill, radius: 4)
        g.text(L("Choose Folder…"), in: button, style: TextStyle.body.aligned(NDW_ALIGN_CENTER), color: theme.textOnAccent)
        if showsFocusRing, focusedID == Self.buttonID {
            g.focusRing(button, radius: 4, theme: theme)
        }
    }
}
