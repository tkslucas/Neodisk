// The file outline: a virtual (owner-data) report ListView, so a million-row tree costs only the rows on
// screen, and the control brings keyboard navigation, multi-selection and Narrator support with it. Tree
// structure comes from the item indent and an expander glyph in the image column.

import CNeodiskWin
import Foundation
import WinSDK

/// ListView and notification codes. The SDK spells them as unsigned wraparound expressions Swift doesn't import.
enum LV {
    static let first: UINT = 0x1000
    static let setBkColor = first + 1
    static let setImageList = first + 3
    static let getNextItem = first + 12
    static let getItemRect = first + 14
    static let ensureVisible = first + 19
    static let redrawItems = first + 21
    static let setColumnWidth = first + 30
    static let getHeader = first + 31
    static let setTextColor = first + 36
    static let setTextBkColor = first + 38
    static let setItemState = first + 43
    static let setItemCount = first + 47
    static let getSelectedCount = first + 50
    static let setExtendedStyle = first + 54
    static let subItemHitTest = first + 57
    static let insertColumn = first + 97
    static let setColumn = first + 96

    static func code(_ value: Int32) -> UINT { UINT(bitPattern: value) }
    static let itemChanged = code(-101)
    static let odStateChanged = code(-115)
    static let itemActivate = code(-114)
    static let keyDown = code(-155)
    static let getDispInfo = code(-177)
    static let odFindItem = code(-179)
    static let click = code(-2)
    static let doubleClick = code(-3)
    static let rightClick = code(-5)
    static let setFocus = code(-7)
    static let customDraw = code(-12)
}

@MainActor
final class OutlineView {
    enum Expander: Int32 {
        case none = 0, collapsed = 1, expanded = 2
    }

    struct Column {
        let title: String
        let width: Double
        let trailing: Bool
    }

    let hwnd: HWND
    private(set) var header: HWND?
    let columns: [Column]

    /// Text for (row, column).
    var cellText: ((Int, Int) -> String)?
    var rowShape: ((Int) -> (depth: Int, expander: Expander))?
    var onSelectionChange: (([Int], Int?) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onToggle: ((Int) -> Void)?
    /// Keys the list doesn't handle itself (Left/Right on the tree, Backspace, Delete); true when handled.
    var onKey: ((Int32) -> Bool)?
    var onFocus: (() -> Void)?

    private var rowCount = 0
    private var isSyncing = false
    private var font: HFONT?
    private var images: HIMAGELIST?
    private var textBuffer: [WCHAR] = []
    private var scale: Float = 1

    init(parent: HWND, columns: [Column], name: String) {
        self.columns = columns
        let style = dword(WS_CHILD) | dword(WS_VISIBLE) | dword(WS_TABSTOP) | dword(WS_CLIPSIBLINGS)
            | dword(LVS_REPORT) | dword(LVS_OWNERDATA) | dword(LVS_SHOWSELALWAYS)
        hwnd = withWide("SysListView32") { className in
            withWide(name) { title in
                CreateWindowExW(0, className, title, style, 0, 0, 0, 0, parent, nil, GetModuleHandleW(nil), nil)
            }
        }!
        let extended = LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_HEADERDRAGDROP
        SendMessageW(hwnd, LV.setExtendedStyle, WPARAM(extended), LPARAM(extended))
        header = HWND(bitPattern: Int(SendMessageW(hwnd, LV.getHeader, 0, 0)))
        for (index, column) in columns.enumerated() {
            var title = column.title.wide
            title.withUnsafeMutableBufferPointer { buffer in
                var item = LVCOLUMNW()
                item.mask = UINT(LVCF_TEXT | LVCF_WIDTH | LVCF_FMT | LVCF_SUBITEM)
                item.fmt = column.trailing ? Int32(LVCFMT_RIGHT) : Int32(LVCFMT_LEFT)
                item.cx = Int32(column.width)
                item.pszText = buffer.baseAddress
                item.iSubItem = Int32(index)
                _ = withUnsafeMutablePointer(to: &item) {
                    SendMessageW(hwnd, LV.insertColumn, WPARAM(index), LPARAM(Int(bitPattern: $0)))
                }
            }
        }
        SetWindowSubclass(hwnd, outlineSubclass, 1, DWORD_PTR(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())))
    }

    // MARK: - Appearance

    func apply(theme: Theme, scale: Float) {
        self.scale = scale
        let dark = theme.isDark
        _ = ndw_set_window_theme(hwnd, (dark ? "DarkMode_Explorer" : "Explorer").wide, nil)
        if let header {
            _ = ndw_set_window_theme(header, (dark ? "DarkMode_ItemsView" : "ItemsView").wide, nil)
        }
        let background = theme.layer
        SendMessageW(hwnd, LV.setBkColor, 0, LPARAM(background.colorref))
        SendMessageW(hwnd, LV.setTextBkColor, 0, LPARAM(background.colorref))
        SendMessageW(hwnd, LV.setTextColor, 0, LPARAM(theme.textPrimary.over(background).colorref))

        if let font { DeleteObject(font) }
        font = withWide("Segoe UI Variable Text") { face in
            CreateFontW(
                -Int32((14 * scale).rounded()), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET),
                DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                DWORD(DEFAULT_PITCH), face
            )
        }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1)
        if let header { SendMessageW(header, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1) }

        // The expander column: blank, collapsed, expanded. Its height sets the row height.
        let glyphs: [UInt16] = [0x20, Glyph.chevronRight.rawValue, Glyph.chevronDown.rawValue]
        let width = Int32((20 * scale).rounded()), height = Int32((32 * scale).rounded())
        let fresh = glyphs.withUnsafeBufferPointer {
            ndw_glyph_image_list($0.baseAddress, Int32($0.count), width, height, 10 * scale,
                                 theme.textSecondary.over(background).ndw)
        }
        SendMessageW(hwnd, LV.setImageList, WPARAM(LVSIL_SMALL), LPARAM(Int(bitPattern: fresh)))
        if let images { ImageList_Destroy(images) }
        images = OpaquePointer(fresh)
        for (index, column) in columns.enumerated() where index > 0 {
            SendMessageW(hwnd, LV.setColumnWidth, WPARAM(index), LPARAM(Int((column.width * Double(scale)).rounded())))
        }
        fitNameColumn()
        InvalidateRect(hwnd, nil, true)
    }

    /// The name column takes the width the others leave.
    func fitNameColumn() {
        var client = RECT()
        GetClientRect(hwnd, &client)
        // The client rect excludes a visible scroll bar; keep room for one that's about to appear.
        let hasScrollBar = UInt32(bitPattern: GetWindowLongW(hwnd, GWL_STYLE)) & UInt32(WS_VSCROLL) != 0
        let scrollBar = hasScrollBar ? 0 : Double(GetSystemMetricsForDpi(SM_CXVSCROLL, GetDpiForWindow(hwnd)))
        let others = columns.dropFirst().reduce(0.0) { $0 + $1.width } * Double(scale)
        let width = max(Double(client.right) - others - scrollBar - 1, 160 * Double(scale))
        SendMessageW(hwnd, LV.setColumnWidth, 0, LPARAM(Int(width)))
    }

    // MARK: - Rows

    /// A new row count; `keepScroll` keeps the scroll position (expansion) rather than resetting it.
    func reload(count: Int, keepScroll: Bool) {
        rowCount = count
        let flags = keepScroll ? LPARAM(LVSICF_NOSCROLL | LVSICF_NOINVALIDATEALL) : 0
        SendMessageW(hwnd, LV.setItemCount, WPARAM(count), flags)
        // New rows (search results, another folder) start keyboard focus at the top, not at the old index.
        if !keepScroll { setFocusedRow(count > 0 ? 0 : nil) }
        // The vertical scroll bar may have come or gone with the rows.
        fitNameColumn()
        InvalidateRect(hwnd, nil, false)
    }

    func redraw(rows: ClosedRange<Int>) {
        SendMessageW(hwnd, LV.redrawItems, WPARAM(rows.lowerBound), LPARAM(rows.upperBound))
    }

    func setSelection(_ rows: [Int], focused: Int?) {
        isSyncing = true
        defer { isSyncing = false }
        var clear = LVITEMW()
        clear.stateMask = UINT(LVIS_SELECTED)
        clear.state = 0
        _ = withUnsafeMutablePointer(to: &clear) {
            SendMessageW(hwnd, LV.setItemState, WPARAM(bitPattern: -1), LPARAM(Int(bitPattern: $0)))
        }
        for row in rows where row < rowCount {
            var item = LVITEMW()
            item.stateMask = UINT(LVIS_SELECTED)
            item.state = UINT(LVIS_SELECTED)
            _ = withUnsafeMutablePointer(to: &item) {
                SendMessageW(hwnd, LV.setItemState, WPARAM(row), LPARAM(Int(bitPattern: $0)))
            }
        }
        if let focused, focused < rowCount {
            var item = LVITEMW()
            item.stateMask = UINT(LVIS_FOCUSED)
            item.state = UINT(LVIS_FOCUSED)
            _ = withUnsafeMutablePointer(to: &item) {
                SendMessageW(hwnd, LV.setItemState, WPARAM(focused), LPARAM(Int(bitPattern: $0)))
            }
            SendMessageW(hwnd, LV.ensureVisible, WPARAM(focused), 0)
        }
    }

    private func setFocusedRow(_ row: Int?) {
        let current = focusedRow
        guard current != row else { return }
        isSyncing = true
        defer { isSyncing = false }
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_FOCUSED)
        item.state = 0
        if let current {
            _ = withUnsafeMutablePointer(to: &item) {
                SendMessageW(hwnd, LV.setItemState, WPARAM(current), LPARAM(Int(bitPattern: $0)))
            }
        }
        guard let row else { return }
        item.state = UINT(LVIS_FOCUSED)
        _ = withUnsafeMutablePointer(to: &item) {
            SendMessageW(hwnd, LV.setItemState, WPARAM(row), LPARAM(Int(bitPattern: $0)))
        }
    }

    /// Keyboard entry from the search field above: selects the focused row (the first after new rows) unless a
    /// row is selected already, so Down from the search lands on the best match.
    func enterFromAbove() {
        SetFocus(hwnd)
        guard rowCount > 0, selectedRows.isEmpty else { return }
        let row = focusedRow ?? 0
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        item.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        _ = withUnsafeMutablePointer(to: &item) {
            SendMessageW(hwnd, LV.setItemState, WPARAM(row), LPARAM(Int(bitPattern: $0)))
        }
        SendMessageW(hwnd, LV.ensureVisible, WPARAM(row), 0)
    }

    var selectedRows: [Int] {
        var result: [Int] = []
        var index = -1
        while true {
            let next = Int(SendMessageW(hwnd, LV.getNextItem, WPARAM(bitPattern: Int64(index)), LPARAM(LVNI_SELECTED)))
            guard next >= 0, next != index else { break }
            result.append(next)
            index = next
        }
        return result
    }

    var focusedRow: Int? {
        let row = Int(SendMessageW(hwnd, LV.getNextItem, WPARAM(bitPattern: -1), LPARAM(LVNI_FOCUSED)))
        return row >= 0 ? row : nil
    }

    // MARK: - Notifications (WM_NOTIFY from the parent)

    func handleNotify(_ header: UnsafeMutablePointer<NMHDR>) -> LRESULT? {
        switch header.pointee.code {
        case LV.getDispInfo:
            header.withMemoryRebound(to: NMLVDISPINFOW.self, capacity: 1) { fill(&$0.pointee.item) }
            return 0
        case LV.itemChanged:
            let change = header.withMemoryRebound(to: NMLISTVIEW.self, capacity: 1) { $0.pointee }
            if change.uChanged & UINT(LVIF_STATE) != 0,
               (change.uNewState ^ change.uOldState) & UINT(LVIS_SELECTED | LVIS_FOCUSED) != 0 {
                selectionDidChange()
            }
            return 0
        case LV.odStateChanged:
            selectionDidChange()
            return 0
        case LV.itemActivate:
            if let row = focusedRow { onActivate?(row) }
            return 0
        case LV.click:
            let activate = header.withMemoryRebound(to: NMITEMACTIVATE.self, capacity: 1) { $0.pointee }
            if activate.iItem >= 0, isOnExpander(row: Int(activate.iItem), x: Int(activate.ptAction.x)) {
                onToggle?(Int(activate.iItem))
            }
            return 0
        case LV.keyDown:
            let key = header.withMemoryRebound(to: NMLVKEYDOWN.self, capacity: 1) { $0.pointee.wVKey }
            _ = onKey?(Int32(key))
            return 0
        case LV.setFocus:
            onFocus?()
            return nil
        case LV.odFindItem:
            return -1
        default:
            return nil
        }
    }

    private func selectionDidChange() {
        guard !isSyncing else { return }
        onSelectionChange?(selectedRows, focusedRow)
    }

    private func isOnExpander(row: Int, x: Int) -> Bool {
        guard let shape = rowShape?(row), shape.expander != .none else { return false }
        let indentWidth = Double(20 * scale)
        let start = Double(shape.depth) * indentWidth + 4 * Double(scale)
        return Double(x) >= start && Double(x) < start + indentWidth
    }

    private func fill(_ item: inout LVITEMW) {
        let row = Int(item.iItem)
        guard row >= 0, row < rowCount else { return }
        if item.mask & UINT(LVIF_TEXT) != 0, item.pszText != nil, item.cchTextMax > 0 {
            let text = cellText?(row, Int(item.iSubItem)) ?? ""
            let units = Array(text.utf16.prefix(Int(item.cchTextMax) - 1))
            units.withUnsafeBufferPointer { source in
                item.pszText.update(from: source.baseAddress!, count: units.count)
            }
            item.pszText[units.count] = 0
        }
        if item.iSubItem == 0 {
            let shape = rowShape?(row) ?? (0, .none)
            if item.mask & UINT(LVIF_IMAGE) != 0 { item.iImage = shape.expander.rawValue }
            if item.mask & UINT(LVIF_INDENT) != 0 { item.iIndent = Int32(shape.depth) }
            item.mask |= UINT(LVIF_INDENT)
            item.iIndent = Int32(shape.depth)
        }
    }

    fileprivate func headerCustomDraw(_ lParam: LPARAM) -> LRESULT {
        guard let draw = UnsafeMutablePointer<NMCUSTOMDRAW>(bitPattern: Int(lParam)) else { return 0 }
        switch draw.pointee.dwDrawStage {
        case DWORD(CDDS_PREPAINT):
            return LRESULT(CDRF_NOTIFYITEMDRAW)
        case DWORD(CDDS_ITEMPREPAINT):
            // The dark header theme paints the background but keeps black text.
            SetTextColor(draw.pointee.hdc, Theme.current.textSecondary.over(Theme.current.layer).colorref)
            return LRESULT(CDRF_DODEFAULT)
        default:
            return LRESULT(CDRF_DODEFAULT)
        }
    }
}

private let outlineSubclass: SUBCLASSPROC = { window, message, wParam, lParam, _, reference in
    let handle = Int(bitPattern: window)
    return MainActor.assumeIsolated {
        let hwnd = HWND(bitPattern: handle)
        let view = Unmanaged<OutlineView>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(reference))!).takeUnretainedValue()
        switch Int32(truncatingIfNeeded: message) {
        case WM_NOTIFY:
            if let header = UnsafeMutablePointer<NMHDR>(bitPattern: Int(lParam)), header.pointee.hwndFrom == view.header,
               header.pointee.code == LV.customDraw {
                return view.headerCustomDraw(lParam)
            }
        case WM_GETDLGCODE:
            // Tab belongs to the window's focus order, not the list.
            return DefSubclassProc(hwnd, message, wParam, lParam) & ~LRESULT(DLGC_WANTTAB)
        case WM_SIZE:
            let result = DefSubclassProc(hwnd, message, wParam, lParam)
            view.fitNameColumn()
            return result
        default:
            break
        }
        return DefSubclassProc(hwnd, message, wParam, lParam)
    }
}
