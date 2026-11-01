// The main window, laid out the Windows 11 way: Mica behind the navigation pane and the command bar, the
// content on an opaque layer with a rounded top-left corner. The system draws the title bar (title, caption
// buttons, snap layouts); the client area's top and left bands are an extended frame, so Mica shows through
// wherever they stay clear. Real controls (the outline, the search field) sit on the opaque layer, where
// GDI's drawing is safe.

import CNeodiskWin
import Foundation
import WinSDK

@MainActor
final class MainWindow: Win32Window {
    enum Command {
        case back, forward, up, scan, stop, treemap, sunburst, chooseFolder, search, more, escape, drillIn
    }

    static let className = "NeodiskMainWindow"

    private(set) var sidebar: SidebarView!
    private(set) var commandBar: CommandBarView!
    private(set) var header: HeaderView!
    private(set) var statusBar: StatusBarView!
    private(set) var emptyState: EmptyStateView!
    private(set) var outline: OutlineView!
    private(set) var searchField: HWND!
    private(set) var canvas: HWND!

    var onCommand: ((Command) -> Void)?
    var onSearchChange: ((String) -> Void)?
    var onSearchSubmit: (() -> Void)?
    var onDPIChange: (() -> Void)?
    var onThemeChange: (() -> Void)?
    var onClose: (() -> Void)?
    /// The restored window's outer size in DIPs, and whether it's maximized, as the user leaves them.
    var onResize: ((Double, Double) -> Void)?
    var onMaximize: ((Bool) -> Void)?

    /// False shows the empty state in the content layer.
    var showsWorkspace = false {
        didSet { if showsWorkspace != oldValue { layout() } }
    }
    var isScanning = false

    private var surface: OpaquePointer?
    private var micaEnabled = false
    private var splitFraction = 0.6
    private var isDraggingSplitter = false
    private var isSplitterHovered = false
    private var searchHasFocus = false
    private var searchBrush: HBRUSH?
    private var searchFocusedBrush: HBRUSH?
    private var searchFont: HFONT?
    private var modalPumpTimer: UINT_PTR = 0
    private var isShown = false

    /// `makeCanvas` creates the map surface as a child of the window it's given.
    init(title: String, width: Double, height: Double, makeCanvas: (HWND) -> HWND?) {
        super.init()
        Self.registerClass(Self.className, style: UINT(CS_DBLCLKS))
        create(
            className: Self.className, title: title,
            style: dword(WS_OVERLAPPEDWINDOW) | dword(WS_CLIPCHILDREN)
        )
        surface = ndw_surface_create(hwnd)
        placeCentered(width: width, height: height)

        sidebar = SidebarView(parent: hwnd)
        commandBar = CommandBarView(parent: hwnd)
        header = HeaderView(parent: hwnd)
        statusBar = StatusBarView(parent: hwnd)
        emptyState = EmptyStateView(parent: hwnd)
        canvas = makeCanvas(hwnd)
        _ = ndw_set_accessible_name(canvas, L("Visualization").wide)
        searchField = withWide("EDIT") { className in
            withWide("") { title in
                CreateWindowExW(
                    0, className, title,
                    dword(WS_CHILD) | dword(WS_VISIBLE) | dword(WS_TABSTOP) | dword(ES_AUTOHSCROLL),
                    0, 0, 0, 0, hwnd, HMENU(bitPattern: Self.searchID), GetModuleHandleW(nil), nil
                )
            }
        }
        _ = withWide(L("Search entire scan")) { cue in
            SendMessageW(searchField, 0x1501, 1, LPARAM(Int(bitPattern: cue)))  // EM_SETCUEBANNER
        }
        _ = ndw_set_accessible_name(searchField, L("Search").wide)
        outline = OutlineView(parent: hwnd, columns: [
            .init(title: L("Name"), width: 320, trailing: false),
            .init(title: L("Size"), width: 96, trailing: true),
            .init(title: L("Share"), width: 88, trailing: true),
            .init(title: L("Files"), width: 84, trailing: true),
            .init(title: L("Modified"), width: 132, trailing: true),
        ], name: L("Files"))
        _ = ndw_set_accessible_name(outline.hwnd, L("Files").wide)
        commandBar.onCommand = { [unowned self] command in
            switch command {
            case .back: self.onCommand?(.back)
            case .forward: self.onCommand?(.forward)
            case .up: self.onCommand?(.up)
            case .scan: self.onCommand?(self.isScanning ? .stop : .scan)
            case .treemap: self.onCommand?(.treemap)
            case .sunburst: self.onCommand?(.sunburst)
            case .openFolder: self.onCommand?(.chooseFolder)
            case .more: self.onCommand?(.more)
            }
        }
        sidebar.onChooseFolder = { [unowned self] in self.onCommand?(.chooseFolder) }
        emptyState.onChooseFolder = { [unowned self] in self.onCommand?(.chooseFolder) }

        applyTheme()
        layout()
        MessageLoop.preTranslate = { [unowned self] message in self.preTranslate(&message) }
    }

    private static let searchID = 100

    var scale: Float { WindowMetrics.scale(for: hwnd) }

    /// The saved size, kept inside the monitor's work area, centered on it.
    private func placeCentered(width: Double, height: Double) {
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTOPRIMARY)), &monitor)
        let work = monitor.rcWork
        let s = Double(scale)
        let workWidth = Int32(work.right - work.left), workHeight = Int32(work.bottom - work.top)
        let w = min(Int32(width * s), workWidth), h = min(Int32(height * s), workHeight)
        SetWindowPos(hwnd, nil, work.left + (workWidth - w) / 2, work.top + (workHeight - h) / 2, w, h,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    func show(maximized: Bool = false) {
        // The first call takes the launcher's show state; a hidden launcher (a script) still gets a window.
        ShowWindow(hwnd, SW_SHOWDEFAULT)
        if !IsWindowVisible(hwnd) || maximized {
            ShowWindow(hwnd, maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL)
        }
        UpdateWindow(hwnd)
        isShown = true
        // The first stop on open: the locations, like a navigation pane's first item.
        sidebar.focusFromTab(forward: true)
    }

    // MARK: - Appearance

    /// Theme, backdrop and the colors of the controls that don't follow the theme by themselves.
    func applyTheme() {
        let theme = Theme.current
        var dark: WindowsBool = WindowsBool(booleanLiteral: theme.isDark)
        DwmSetWindowAttribute(hwnd, 20, &dark, DWORD(MemoryLayout<WindowsBool>.size))  // DWMWA_USE_IMMERSIVE_DARK_MODE
        var backdrop: Int32 = 2  // DWMSBT_MAINWINDOW: Mica
        micaEnabled = ProcessInfo.processInfo.environment["NEODISK_NO_MICA"] == nil
            && DwmSetWindowAttribute(hwnd, 38, &backdrop, DWORD(MemoryLayout<Int32>.size)) == S_OK  // DWMWA_SYSTEMBACKDROP_TYPE
        ndw_set_app_dark_mode(theme.isDark ? 1 : 0)
        _ = ndw_set_window_theme(searchField, (theme.isDark ? "DarkMode_CFD" : "CFD").wide, nil)
        if let searchBrush { DeleteObject(searchBrush) }
        if let searchFocusedBrush { DeleteObject(searchFocusedBrush) }
        searchBrush = CreateSolidBrush(theme.inputFill.colorref)
        searchFocusedBrush = CreateSolidBrush(theme.inputFillFocused.colorref)
        applyMetrics()
        for view in surfaceViews { view.invalidate() }
        InvalidateRect(hwnd, nil, false)
        // The frame redraws its caption buttons in the new theme.
        SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE))
    }

    /// DPI-dependent resources: fonts and the outline's glyphs.
    private func applyMetrics() {
        let scale = self.scale
        outline.apply(theme: Theme.current, scale: scale)
        if let searchFont { DeleteObject(searchFont) }
        searchFont = withWide("Segoe UI Variable Text") { face in
            CreateFontW(
                -Int32((14 * scale).rounded()), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET),
                DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), face
            )
        }
        SendMessageW(searchField, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: searchFont))), 1)
    }

    private var surfaceViews: [SurfaceView] { [sidebar, commandBar, header, statusBar, emptyState] }

    // MARK: - Layout (DIPs)

    private struct Frames {
        var sidebar = CGRect.zero
        var commandBar = CGRect.zero
        var layer = CGRect.zero
        var header = CGRect.zero
        var canvas = CGRect.zero
        var splitter = CGRect.zero
        var searchBox = CGRect.zero
        var outline = CGRect.zero
        var statusBar = CGRect.zero
        var emptyState = CGRect.zero
    }

    private var clientSize: CGSize {
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let s = Double(scale)
        return CGSize(width: Double(rect.right) / s, height: Double(rect.bottom) / s)
    }

    private var frames: Frames {
        let size = clientSize
        var frames = Frames()
        let sidebarWidth = min(SidebarView.width, max(200, size.width * 0.3))
        frames.sidebar = CGRect(x: 0, y: 0, width: sidebarWidth, height: size.height)
        frames.commandBar = CGRect(x: sidebarWidth, y: 0, width: size.width - sidebarWidth, height: CommandBarView.height)
        frames.layer = CGRect(x: sidebarWidth, y: CommandBarView.height, width: size.width - sidebarWidth,
                              height: size.height - CommandBarView.height)
        let inner = frames.layer.insetBy(dx: 20, dy: 0)
        frames.header = CGRect(x: inner.minX, y: frames.layer.minY + 16, width: inner.width, height: HeaderView.height)
        frames.statusBar = CGRect(x: inner.minX, y: frames.layer.maxY - StatusBarView.height, width: inner.width,
                                  height: StatusBarView.height)
        let top = frames.header.maxY + 8
        let bottom = frames.statusBar.minY - 4
        let available = max(0, bottom - top)
        let searchHeight = 32.0
        let canvasHeight = max(120, min(available - searchHeight - 140, available * splitFraction))
        frames.canvas = CGRect(x: inner.minX, y: top, width: inner.width, height: max(0, canvasHeight))
        frames.splitter = CGRect(x: inner.minX, y: frames.canvas.maxY, width: inner.width, height: 12)
        frames.searchBox = CGRect(x: inner.minX, y: frames.splitter.maxY, width: inner.width, height: searchHeight)
        frames.outline = CGRect(x: inner.minX, y: frames.searchBox.maxY + 8, width: inner.width,
                                height: max(0, bottom - frames.searchBox.maxY - 8))
        frames.emptyState = CGRect(x: inner.minX, y: frames.layer.minY + 16, width: inner.width,
                                   height: max(0, frames.layer.maxY - frames.layer.minY - 32))
        return frames
    }

    func layout() {
        guard hwnd != nil, sidebar != nil else { return }
        let scale = self.scale
        let frames = self.frames
        let s = Double(scale)
        sidebar.setFrame(frames.sidebar, scale: scale)
        commandBar.setFrame(frames.commandBar, scale: scale)
        header.setFrame(frames.header, scale: scale)
        statusBar.setFrame(frames.statusBar, scale: scale)
        emptyState.setFrame(frames.emptyState, scale: scale)
        place(canvas, frames.canvas, s)
        place(outline.hwnd, frames.outline, s)
        // The edit sits inside the drawn box, one line tall and vertically centered.
        let box = frames.searchBox
        let lineHeight = 20.0
        place(searchField, CGRect(x: box.minX + 12, y: box.midY - lineHeight / 2, width: box.width - 12 - 40,
                                  height: lineHeight), s)
        let workspace = showsWorkspace
        for window in [canvas, outline.hwnd, searchField] as [HWND?] {
            ShowWindow(window, workspace ? SW_SHOWNA : SW_HIDE)
        }
        // The empty state carries its own title.
        for window in [header.hwnd, statusBar.hwnd] as [HWND?] {
            ShowWindow(window, workspace ? SW_SHOWNA : SW_HIDE)
        }
        ShowWindow(emptyState.hwnd, workspace ? SW_HIDE : SW_SHOWNA)
        // Mica fills the extended frame: the pane, the command bar, and the band the layer's corner rounds into.
        if micaEnabled {
            var margins = MARGINS(
                cxLeftWidth: Int32((frames.layer.minX + 8) * s), cxRightWidth: 0,
                cyTopHeight: Int32((frames.layer.minY + 8) * s), cyBottomHeight: 0
            )
            DwmExtendFrameIntoClientArea(hwnd, &margins)
        }
        InvalidateRect(hwnd, nil, false)
    }

    private func place(_ window: HWND?, _ frame: CGRect, _ s: Double) {
        let x = Int32((frame.minX * s).rounded()), y = Int32((frame.minY * s).rounded())
        let right = Int32((frame.maxX * s).rounded()), bottom = Int32((frame.maxY * s).rounded())
        SetWindowPos(window, nil, x, y, right - x, bottom - y, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    // MARK: - Painting

    private func paint() {
        var paint = PAINTSTRUCT()
        let dc = BeginPaint(hwnd, &paint)
        defer { EndPaint(hwnd, &paint) }
        let dirty = paint.rcPaint
        guard let surface, let raw = ndw_surface_begin(
            surface, dc, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top
        ) else { return }
        let g = Gfx(raw: raw, scale: scale)
        let theme = Theme.current
        let frames = self.frames
        if !micaEnabled {
            g.fill(CGRect(origin: .zero, size: clientSize), theme.solidBackground)
        }
        // Past the right and bottom edges, so only the top-left corner rounds.
        let layer = CGRect(x: frames.layer.minX, y: frames.layer.minY, width: frames.layer.width + 16,
                           height: frames.layer.height + 16)
        g.fill(layer, theme.layer, radius: 8)
        g.stroke(layer, theme.layerStroke, radius: 8)
        if showsWorkspace {
            let box = frames.searchBox
            g.fill(box, searchHasFocus ? theme.inputFillFocused : theme.inputFill, radius: 4)
            g.stroke(box, theme.controlStroke, radius: 4)
            let underline = searchHasFocus ? 2.0 : 1.0
            g.clip(box.insetBy(dx: 1, dy: 0)) {
                g.fill(CGRect(x: box.minX + 2, y: box.maxY - underline, width: box.width - 4, height: underline),
                       searchHasFocus ? theme.accentFill : theme.controlStrongStroke)
            }
            g.icon(.search, in: CGRect(x: box.maxX - 36, y: box.minY, width: 32, height: box.height), size: 14,
                   color: theme.textSecondary)
            if isSplitterHovered || isDraggingSplitter {
                let grip = CGRect(x: frames.splitter.midX - 16, y: frames.splitter.midY - 2, width: 32, height: 4)
                g.fill(grip, theme.controlStrongStroke, radius: 2)
            }
        }
        ndw_surface_end(surface)
    }

    // MARK: - Keyboard

    /// The Tab order: the pane, the command bar, then the content.
    private var focusOrder: [HWND] {
        var order: [HWND] = [sidebar.hwnd, commandBar.hwnd]
        if showsWorkspace {
            order += [canvas, searchField, outline.hwnd]
        } else {
            order.append(emptyState.hwnd)
        }
        return order.filter { IsWindowVisible($0) && IsWindowEnabled($0) }
    }

    private func surfaceView(for window: HWND?) -> SurfaceView? {
        surfaceViews.first { $0.hwnd == window }
    }

    func focusSearch() {
        SetFocus(searchField)
        SendMessageW(searchField, UINT(EM_SETSEL), 0, -1)
    }

    var searchText: String {
        get {
            let length = Int(GetWindowTextLengthW(searchField))
            var buffer = [WCHAR](repeating: 0, count: length + 1)
            GetWindowTextW(searchField, &buffer, Int32(buffer.count))
            return String(wideBuffer: buffer)
        }
        set {
            guard newValue != searchText else { return }
            _ = withWide(newValue) { SetWindowTextW(searchField, $0) }
        }
    }

    private func moveFocus(forward: Bool) {
        FocusCues.keyboard = true
        let focused = GetFocus()
        if let view = surfaceView(for: focused), view.moveFocus(forward: forward) {
            return
        }
        let order = focusOrder
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0 == focused || IsChild($0, focused) } ?? -1
        let next = order[((index + (forward ? 1 : -1)) % order.count + order.count) % order.count]
        if let view = surfaceView(for: next) {
            view.focusFromTab(forward: forward)
        } else {
            SetFocus(next)
            if next == searchField { SendMessageW(searchField, UINT(EM_SETSEL), 0, -1) }
        }
        for view in surfaceViews { view.invalidate() }
    }

    private func preTranslate(_ message: inout MSG) -> Bool {
        guard message.hwnd == hwnd || IsChild(hwnd, message.hwnd) else { return false }
        let kind = Int32(truncatingIfNeeded: message.message)
        if kind == WM_LBUTTONDOWN || kind == WM_RBUTTONDOWN {
            FocusCues.keyboard = false
            return false
        }
        guard kind == WM_KEYDOWN || kind == WM_SYSKEYDOWN else { return false }
        let key = Int32(truncatingIfNeeded: message.wParam)
        let control = isKeyDown(VK_CONTROL), alt = isKeyDown(VK_MENU), shift = isKeyDown(VK_SHIFT)
        let inSearch = message.hwnd == searchField
        switch (key, control, alt) {
        case (VK_TAB, false, false):
            moveFocus(forward: !shift)
        case (VK_F5, false, false), (0x52, true, false):  // F5, Ctrl+R
            onCommand?(.scan)
        case (0x46, true, false):  // Ctrl+F
            onCommand?(.search)
        case (0x4F, true, false):  // Ctrl+O
            onCommand?(.chooseFolder)
        case (0x31, true, false):  // Ctrl+1
            onCommand?(.treemap)
        case (0x32, true, false):  // Ctrl+2
            onCommand?(.sunburst)
        case (VK_LEFT, false, true):
            onCommand?(.back)
        case (VK_RIGHT, false, true):
            onCommand?(.forward)
        case (VK_UP, false, true):
            onCommand?(.up)
        case (VK_BACK, false, false) where !inSearch:
            onCommand?(.up)
        case (VK_ESCAPE, false, false):
            if inSearch, !searchText.isEmpty {
                searchText = ""
            } else {
                onCommand?(isScanning ? .stop : .escape)
            }
        case (VK_RETURN, false, false) where inSearch:
            onSearchSubmit?()
        case (VK_DOWN, false, false) where inSearch:
            SetFocus(outline.hwnd)
        default:
            return false
        }
        return true
    }

    // MARK: - Messages

    override func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(truncatingIfNeeded: message) {
        case WM_PAINT:
            paint()
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SIZE:
            layout()
            if isShown, wParam == WPARAM(SIZE_RESTORED) || wParam == WPARAM(SIZE_MAXIMIZED) {
                onMaximize?(wParam == WPARAM(SIZE_MAXIMIZED))
                if wParam == WPARAM(SIZE_RESTORED) {
                    var frame = RECT()
                    GetWindowRect(hwnd, &frame)
                    let s = Double(scale)
                    onResize?(Double(frame.right - frame.left) / s, Double(frame.bottom - frame.top) / s)
                }
            }
            return 0
        case WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)), hwnd != nil {
                let s = Double(scale)
                info.pointee.ptMinTrackSize = POINT(x: Int32(640 * s), y: Int32(440 * s))
            }
            return 0
        case WM_DPICHANGED:
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                             suggested.bottom - suggested.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            applyMetrics()
            layout()
            for view in surfaceViews {
                view.invalidate()
                view.refreshAccessibility()
            }
            onDPIChange?()
            return 0
        case WM_SETTINGCHANGE:
            if let text = UnsafePointer<WCHAR>(bitPattern: Int(lParam)), String(wide: text) == "ImmersiveColorSet" {
                themeMayHaveChanged()
            }
            return nil
        case WM_DWMCOLORIZATIONCOLORCHANGED, WM_SYSCOLORCHANGE, WM_THEMECHANGED:
            themeMayHaveChanged()
            return nil
        case WM_CTLCOLOREDIT:
            guard HWND(bitPattern: Int(lParam)) == searchField, let dc = HDC(bitPattern: Int(bitPattern: UInt(wParam))) else { return nil }
            let theme = Theme.current
            let fill = searchHasFocus ? theme.inputFillFocused : theme.inputFill
            SetTextColor(dc, theme.textPrimary.over(fill).colorref)
            SetBkColor(dc, fill.colorref)
            let brush = searchHasFocus ? searchFocusedBrush : searchBrush
            return LRESULT(Int(bitPattern: brush))
        case WM_COMMAND:
            if loWord(wParam) == Self.searchID {
                switch hiWord(wParam) {
                case Int(EN_CHANGE): onSearchChange?(searchText)
                case Int(EN_SETFOCUS), Int(EN_KILLFOCUS):
                    searchHasFocus = hiWord(wParam) == Int(EN_SETFOCUS)
                    InvalidateRect(hwnd, nil, false)
                    InvalidateRect(searchField, nil, true)
                default: break
                }
                return 0
            }
            return nil
        case WM_NOTIFY:
            if let header = UnsafeMutablePointer<NMHDR>(bitPattern: Int(lParam)), header.pointee.hwndFrom == outline.hwnd,
               let result = outline.handleNotify(header) {
                return result
            }
            return nil
        case WM_SETCURSOR:
            if HWND(bitPattern: Int(bitPattern: UInt(wParam))) == hwnd, showsWorkspace {
                var point = POINT()
                GetCursorPos(&point)
                ScreenToClient(hwnd, &point)
                let s = Double(scale)
                if frames.splitter.contains(CGPoint(x: Double(point.x) / s, y: Double(point.y) / s)) {
                    SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32645)))  // IDC_SIZENS
                    return 1
                }
            }
            return nil
        case WM_MOUSEMOVE:
            let (x, y) = pointFromLParam(lParam)
            let s = Double(scale)
            let point = CGPoint(x: Double(x) / s, y: Double(y) / s)
            if isDraggingSplitter {
                let frames = self.frames
                let top = frames.header.maxY + 8
                let bottom = frames.statusBar.minY - 4
                splitFraction = min(0.85, max(0.2, (point.y - top) / max(1, bottom - top)))
                layout()
            } else {
                let hovered = showsWorkspace && frames.splitter.contains(point)
                if hovered != isSplitterHovered {
                    isSplitterHovered = hovered
                    InvalidateRect(hwnd, nil, false)
                    if hovered {
                        var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size),
                                                    dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
                        TrackMouseEvent(&track)
                    }
                }
            }
            return 0
        case WM_MOUSELEAVE:
            if isSplitterHovered {
                isSplitterHovered = false
                InvalidateRect(hwnd, nil, false)
            }
            return 0
        case WM_LBUTTONDOWN:
            let (x, y) = pointFromLParam(lParam)
            let s = Double(scale)
            if showsWorkspace, frames.splitter.contains(CGPoint(x: Double(x) / s, y: Double(y) / s)) {
                isDraggingSplitter = true
                SetCapture(hwnd)
            }
            return 0
        case WM_LBUTTONUP:
            if isDraggingSplitter {
                isDraggingSplitter = false
                ReleaseCapture()
                InvalidateRect(hwnd, nil, false)
            }
            return 0
        case WM_ENTERSIZEMOVE, WM_ENTERMENULOOP:
            // A modal loop owns the thread: keep the main queue (scan progress) moving.
            if modalPumpTimer == 0 { modalPumpTimer = SetTimer(hwnd, 99, 16, nil) }
            return nil
        case WM_EXITSIZEMOVE, WM_EXITMENULOOP:
            if modalPumpTimer != 0 {
                KillTimer(hwnd, modalPumpTimer)
                modalPumpTimer = 0
            }
            return nil
        case WM_TIMER:
            if wParam == 99 { MessageLoop.drainMainQueue() }
            return 0
        case WM_ACTIVATE:
            // Focus comes back where it was; the system default would leave it on the frame.
            return nil
        case WM_CLOSE:
            onClose?()
            DestroyWindow(hwnd)
            return 0
        case WM_DESTROY:
            if let surface { ndw_surface_destroy(surface) }
            surface = nil
            PostQuitMessage(0)
            return 0
        default:
            return nil
        }
    }

    private func themeMayHaveChanged() {
        guard Theme.reload() else { return }
        applyTheme()
        onThemeChange?()
    }
}
