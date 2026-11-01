// The navigation pane on Mica: volumes with their capacity, folders scanned before, and the folder picker.
// One tab stop; the arrow keys walk the rows, Enter or Space opens one.

import CNeodiskWin
import Foundation
import WinSDK

@MainActor
final class SidebarView: SurfaceView {
    struct Row: Equatable {
        var id: String
        var title: String
        var subtitle: String
        var tooltip: String
        var glyph: Glyph
        /// Used share of the volume, 0...1, or nil for no bar.
        var usedFraction: Double?
        /// Colored parts of the bar (kind shares of a scanned volume), each a fraction of the whole.
        var segments: [(fraction: Double, color: RGBA)] = []

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.tooltip == rhs.tooltip
                && lhs.glyph == rhs.glyph && lhs.usedFraction == rhs.usedFraction
                && lhs.segments.map(\.fraction) == rhs.segments.map(\.fraction)
                && lhs.segments.map(\.color) == rhs.segments.map(\.color)
        }
    }

    struct Section: Equatable {
        var title: String
        var rows: [Row]
    }

    struct State: Equatable {
        var sections: [Section] = []
        var selectedID: String?
    }

    var state = State() {
        didSet {
            guard state != oldValue else { return }
            if let focusedID, !allIDs.contains(focusedID) { self.focusedID = nil }
            invalidate()
            refreshAccessibility()
        }
    }
    var onOpen: ((String) -> Void)?
    var onChooseFolder: (() -> Void)?

    static let width: Double = 272
    private static let chooseFolderID: Int32 = 9000

    init(parent: HWND) {
        super.init(parent: parent, role: NDW_ROLE_PANE, name: L("Locations"))
    }

    // MARK: - Layout

    private struct Placed {
        let id: Int32
        let row: Row
        let frame: CGRect
        let section: Int32
    }

    private struct Layout {
        var headers: [(id: Int32, title: String, frame: CGRect)] = []
        var rows: [Placed] = []
        var chooseFolder = CGRect.zero
    }

    private func layout() -> Layout {
        var result = Layout()
        var y = 8.0
        let width = bounds.width
        var nextID: Int32 = 1
        for (index, section) in state.sections.enumerated() where !section.rows.isEmpty {
            let sectionID = Int32(index + 1) * 1000
            result.headers.append((sectionID, section.title, CGRect(x: 4, y: y, width: width - 8, height: 32)))
            y += 32
            for row in section.rows {
                let height = row.usedFraction == nil ? 52.0 : 60.0
                result.rows.append(Placed(
                    id: sectionID + nextID, row: row,
                    frame: CGRect(x: 4, y: y, width: width - 8, height: height), section: sectionID
                ))
                nextID += 1
                y += height + 2
            }
            y += 8
        }
        result.chooseFolder = CGRect(x: 4, y: y, width: width - 8, height: 40)
        return result
    }

    private var allIDs: [Int32] {
        layout().rows.map(\.id) + [Self.chooseFolderID]
    }

    override func elements() -> [Element] {
        let layout = self.layout()
        var result: [Element] = []
        for header in layout.headers {
            let rows = layout.rows.filter { $0.section == header.id }
            let frame = rows.reduce(header.frame) { $0.union($1.frame) }
            result.append(Element(id: header.id, role: NDW_ROLE_LIST, name: header.title, frame: frame, interactive: false))
        }
        for placed in layout.rows {
            result.append(Element(
                id: placed.id, parent: placed.section, role: NDW_ROLE_LIST_ITEM,
                name: placed.row.title, help: placed.row.subtitle + "\n" + placed.row.tooltip,
                frame: placed.frame, focusable: true, selected: placed.row.id == state.selectedID
            ))
        }
        result.append(Element(
            id: Self.chooseFolderID, role: NDW_ROLE_BUTTON, name: L("Choose Folder…"),
            help: "Ctrl+O", automationID: "chooseFolder", frame: layout.chooseFolder, focusable: true
        ))
        return result
    }

    /// One tab stop: the focused row, else the selected one, else the first.
    override func tabStops() -> [Int32] {
        if let focusedID { return [focusedID] }
        let layout = self.layout()
        if let selected = layout.rows.first(where: { $0.row.id == state.selectedID }) { return [selected.id] }
        return [layout.rows.first?.id ?? Self.chooseFolderID]
    }

    override func activate(_ id: Int32, fromKeyboard: Bool) {
        if id == Self.chooseFolderID {
            onChooseFolder?()
        } else if let placed = layout().rows.first(where: { $0.id == id }) {
            onOpen?(placed.row.id)
        }
    }

    override func keyDown(_ virtualKey: Int32) -> Bool {
        let ids = allIDs
        guard !ids.isEmpty else { return false }
        let index = focusedID.flatMap { ids.firstIndex(of: $0) }
        switch virtualKey {
        case VK_UP: focusedID = ids[max(0, (index ?? 0) - 1)]
        case VK_DOWN: focusedID = ids[min(ids.count - 1, (index ?? -1) + 1)]
        case VK_HOME: focusedID = ids.first
        case VK_END: focusedID = ids.last
        default: return false
        }
        return true
    }

    // MARK: - Drawing

    override func draw(_ g: Gfx) {
        let theme = self.theme
        let layout = self.layout()
        for header in layout.headers {
            g.text(header.title, in: header.frame.insetBy(dx: 12, dy: 0), style: TextStyle(size: 12, weight: 600),
                   color: theme.textSecondary)
        }
        for placed in layout.rows {
            drawRow(g, placed, theme: theme)
        }
        let choose = layout.chooseFolder
        let chooseHovered = hoveredID == Self.chooseFolderID
        if chooseHovered {
            g.fill(choose, pressedID == Self.chooseFolderID ? theme.subtlePressed : theme.subtleHover, radius: 4)
        }
        g.icon(.add, in: CGRect(x: choose.minX + 12, y: choose.minY, width: 16, height: choose.height), color: theme.textPrimary)
        g.text(L("Choose Folder…"), in: CGRect(x: choose.minX + 44, y: choose.minY, width: choose.width - 52, height: choose.height),
               color: theme.textPrimary)
        if showsFocusRing, focusedID == Self.chooseFolderID {
            g.focusRing(choose, radius: 4, theme: theme)
        }
    }

    private func drawRow(_ g: Gfx, _ placed: Placed, theme: Theme) {
        let frame = placed.frame
        let row = placed.row
        let isSelected = row.id == state.selectedID
        let isHovered = hoveredID == placed.id
        let isPressed = isHovered && pressedID == placed.id
        if isPressed {
            g.fill(frame, theme.subtlePressed, radius: 4)
        } else if isSelected || isHovered {
            g.fill(frame, theme.subtleHover, radius: 4)
        }
        if isSelected {
            // The selection pill, as in the system's navigation panes.
            g.fill(CGRect(x: frame.minX, y: frame.midY - 8, width: 3, height: 16), theme.accentFill, radius: 1.5)
        }
        let textX = frame.minX + 44
        let textWidth = frame.width - 44 - 12
        g.icon(row.glyph, in: CGRect(x: frame.minX + 12, y: frame.minY + 8, width: 20, height: 20), size: 16,
               color: isSelected ? theme.accentText : theme.textPrimary)
        g.text(row.title, in: CGRect(x: textX, y: frame.minY + 8, width: textWidth, height: 20), color: theme.textPrimary)
        g.text(row.subtitle, in: CGRect(x: textX, y: frame.minY + 28, width: textWidth, height: 16),
               style: .captionNumeric, color: theme.textSecondary)
        if let used = row.usedFraction {
            let track = CGRect(x: textX, y: frame.minY + 48, width: textWidth, height: 4)
            g.fill(track, theme.track, radius: 2)
            g.clip(track) {
                if row.segments.isEmpty {
                    g.fill(CGRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, used)), height: 4),
                           theme.accentFill, radius: 2)
                } else {
                    var x = track.minX
                    for segment in row.segments {
                        let width = track.width * segment.fraction
                        g.fill(CGRect(x: x, y: track.minY, width: width, height: 4), segment.color)
                        x += width
                    }
                }
            }
        }
        if showsFocusRing, focusedID == placed.id {
            g.focusRing(frame, radius: 4, theme: theme)
        }
    }
}
