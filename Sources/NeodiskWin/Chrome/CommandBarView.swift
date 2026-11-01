// The command bar over the content: navigation, scan, the map switch, and the overflow menu. Buttons stay put
// and disable when they can't act (a product rule shared with the other apps); Rescan becomes Stop while a
// scan runs.

import CNeodiskWin
import Foundation
import WinSDK

@MainActor
final class CommandBarView: SurfaceView {
    enum Command: Int32, CaseIterable {
        case back = 1, forward, up, scan, treemap, sunburst, openFolder, more
    }

    struct State: Equatable {
        var canGoBack = false
        var canGoForward = false
        var canGoUp = false
        var canScan = false
        var isScanning = false
        var showsSunburst = false
        var hasContent = false
    }

    var state = State() {
        didSet {
            guard state != oldValue else { return }
            invalidate()
            refreshAccessibility()
        }
    }
    var onCommand: ((Command) -> Void)?

    static let height: Double = 48

    init(parent: HWND) {
        super.init(parent: parent, role: NDW_ROLE_TOOLBAR, name: L("Commands"))
    }

    // MARK: - Layout

    private struct Item {
        let command: Command
        let glyph: Glyph
        let label: String?
        let tooltip: String
        let frame: CGRect
        let enabled: Bool
        let selected: Bool
    }

    private func items() -> [Item] {
        // Narrow windows drop labels, the far-end ones first, before anything overlaps.
        for compact in 0...2 {
            let laidOut = items(compact: compact)
            let leading = laidOut.filter { $0.command != .openFolder && $0.command != .more }.map(\.frame.maxX).max() ?? 0
            let trailing = laidOut.filter { $0.command == .openFolder || $0.command == .more }.map(\.frame.minX).min() ?? 0
            if leading + 8 <= trailing || compact == 2 { return laidOut }
        }
        return []
    }

    private func items(compact: Int) -> [Item] {
        let height = 36.0
        let top = (Self.height - height) / 2
        var x = 4.0
        var result: [Item] = []
        func add(_ command: Command, _ glyph: Glyph, label: String?, tooltip: String, enabled: Bool,
                 selected: Bool = false, gapBefore: Double = 0) {
            x += gapBefore
            let width = label.map { 40 + Gfx.textWidth($0) + 12 } ?? 40
            result.append(Item(
                command: command, glyph: glyph, label: label, tooltip: tooltip,
                frame: CGRect(x: x, y: top, width: width, height: height), enabled: enabled, selected: selected
            ))
            x += width + 4
        }
        add(.back, .back, label: nil, tooltip: L("Back") + " (Alt+Left)", enabled: state.canGoBack)
        add(.forward, .forward, label: nil, tooltip: L("Forward") + " (Alt+Right)", enabled: state.canGoForward)
        add(.up, .up, label: nil, tooltip: L("Enclosing Folder") + " (Backspace)", enabled: state.canGoUp)
        if state.isScanning {
            add(.scan, .stop, label: L("Stop"), tooltip: L("Stop Scan") + " (Esc)", enabled: true, gapBefore: 9)
        } else {
            add(.scan, .refresh, label: L("Rescan"), tooltip: L("Rescan") + " (F5)", enabled: state.canScan, gapBefore: 9)
        }
        let viewLabels = compact < 2
        add(.treemap, .treemap, label: viewLabels ? L("Treemap") : nil, tooltip: L("Treemap") + " (Ctrl+1)",
            enabled: state.hasContent, selected: !state.showsSunburst, gapBefore: 9)
        add(.sunburst, .sunburst, label: viewLabels ? L("Sunburst") : nil, tooltip: L("Sunburst") + " (Ctrl+2)",
            enabled: state.hasContent, selected: state.showsSunburst)
        // The rest sits at the far end.
        let trailing: [(Command, Glyph, String?, String)] = [
            (.openFolder, .openFolder, compact == 0 ? L("Choose Folder…") : nil, L("Choose a Folder or Disk") + " (Ctrl+O)"),
            (.more, .more, nil, L("More")),
        ]
        var right = bounds.width - 4
        for (command, glyph, label, tooltip) in trailing.reversed() {
            let width = label.map { 40 + Gfx.textWidth($0) + 12 } ?? 40
            right -= width
            result.append(Item(
                command: command, glyph: glyph, label: label, tooltip: tooltip,
                frame: CGRect(x: right, y: top, width: width, height: height), enabled: true, selected: false
            ))
            right -= 4
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The separators between groups, as x positions.
    private func separators(_ items: [Item]) -> [Double] {
        var result: [Double] = []
        for (previous, next) in zip(items, items.dropFirst()) where next.frame.minX - previous.frame.maxX > 8 {
            if next.command == .openFolder { continue }
            result.append((previous.frame.maxX + next.frame.minX) / 2)
        }
        return result
    }

    override func elements() -> [Element] {
        items().map { item in
            Element(
                id: item.command.rawValue,
                role: item.command == .treemap || item.command == .sunburst ? NDW_ROLE_RADIO : NDW_ROLE_BUTTON,
                name: item.label ?? item.tooltip.components(separatedBy: " (").first ?? item.tooltip,
                help: item.tooltip,
                automationID: "\(item.command)",
                frame: item.frame,
                focusable: true,
                selected: item.selected,
                enabled: item.enabled
            )
        }
    }

    override func activate(_ id: Int32, fromKeyboard: Bool) {
        guard let command = Command(rawValue: id), items().first(where: { $0.command == command })?.enabled == true else {
            return
        }
        onCommand?(command)
    }

    // The toolbar is one tab stop, like the sidebar: Tab always enters on its first enabled button and leaves
    // from any button; the arrow keys, Home and End move between buttons.

    override func focusFromTab(forward: Bool) {
        focusedID = tabStops().first
        SetFocus(hwnd)
    }

    override func moveFocus(forward: Bool) -> Bool { false }

    private func moveAlongToolbar(forward: Bool) -> Bool {
        let stops = tabStops()
        guard let current = focusedID, let index = stops.firstIndex(of: current) else {
            focusedID = stops.first
            return true
        }
        let next = forward ? index + 1 : index - 1
        if stops.indices.contains(next) { focusedID = stops[next] }
        return true
    }

    override func keyDown(_ virtualKey: Int32) -> Bool {
        switch virtualKey {
        case VK_LEFT: return moveAlongToolbar(forward: false)
        case VK_RIGHT: return moveAlongToolbar(forward: true)
        case VK_HOME:
            focusedID = tabStops().first
            return true
        case VK_END:
            focusedID = tabStops().last
            return true
        default: return false
        }
    }

    /// Where a dropdown for `command` should open, in screen pixels.
    func anchor(for command: Command) -> POINT {
        guard let item = items().first(where: { $0.command == command }) else { return POINT() }
        let s = Double(scale)
        var point = POINT(x: Int32(item.frame.minX * s), y: Int32(item.frame.maxY * s))
        ClientToScreen(hwnd, &point)
        return point
    }

    // MARK: - Drawing

    override func draw(_ g: Gfx) {
        let theme = self.theme
        let items = self.items()
        for x in separators(items) {
            g.hairline(x0: x, y0: 14, x1: x, y1: Self.height - 14, theme.divider)
        }
        for item in items {
            let id = item.command.rawValue
            let isHovered = hoveredID == id && item.enabled
            let isPressed = pressedID == id && isHovered
            if item.selected {
                g.fill(item.frame, isPressed ? theme.subtlePressed : theme.subtleHover, radius: 4)
            } else if isPressed {
                g.fill(item.frame, theme.subtlePressed, radius: 4)
            } else if isHovered {
                g.fill(item.frame, theme.subtleHover, radius: 4)
            }
            let foreground = !item.enabled ? theme.textDisabled : isPressed ? theme.textSecondary : theme.textPrimary
            let glyphColor = item.selected && item.enabled ? theme.accentText : foreground
            g.icon(item.glyph, in: CGRect(x: item.frame.minX + 12, y: item.frame.minY, width: 16, height: item.frame.height),
                   color: glyphColor)
            if let label = item.label {
                g.text(label, in: CGRect(x: item.frame.minX + 36, y: item.frame.minY, width: item.frame.width - 40,
                                         height: item.frame.height), style: .body, color: foreground)
            }
            if item.selected {
                // The selected view's indicator pill, as in a selector bar.
                let pill = CGRect(x: item.frame.midX - 8, y: item.frame.maxY - 3, width: 16, height: 3)
                g.fill(pill, item.enabled ? theme.accentFill : theme.textDisabled, radius: 1.5)
            }
            if showsFocusRing, focusedID == id {
                g.focusRing(item.frame, radius: 4, theme: theme)
            }
        }
    }
}
