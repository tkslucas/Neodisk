// The treemap and sunburst surface: a child window presenting through a Direct2D swap chain. Rasters arrive from
// background renders through a posted message; hover, selection and focus repaint over the last raster.

import CNeodiskCanvas
import Foundation
import NeodiskAppModel
import WinSDK

@MainActor
final class VizCanvas: CanvasHost {
    enum Mode {
        case treemap
        case sunburst
    }

    let model: VizCanvasModel
    private(set) var hwnd: HWND?
    private(set) var device: D2DCanvas?
    let mailbox = CanvasMailbox()
    let stats = CanvasStats()
    private(set) lazy var treemap = TreemapPresenter(host: self)
    private(set) lazy var sunburst = SunburstPresenter(host: self)

    var mode: Mode = .treemap {
        didSet {
            guard mode != oldValue else { return }
            treemap.pointerMoved(to: nil)
            sunburst.pointerMoved(to: nil)
            activeModelDidChange()
        }
    }

    /// Vsync for the app; the benchmark presents immediately and waits for the device to time real work.
    var presentMode: D2DCanvas.Present = .vsync
    var timesFrames = ProcessInfo.processInfo.environment["NEODISK_CANVAS_STATS"] == "1"

    private var pixelWidth = 0
    private var pixelHeight = 0
    private var dpi: UINT = 96
    private(set) var hasFocus = false
    private var tracksMouseLeave = false
    private var rightClickPoint: CGPoint?

    private static let className: [WCHAR] = Array("NeodiskVizCanvas".utf16) + [0]
    private static var isRegistered = false

    init(parent: HWND, model: VizCanvasModel) {
        self.model = model
        Self.registerClass()
        mailbox.attach(nil)
        let instance = GetModuleHandleW(nil)
        let style = DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_CLIPSIBLINGS)
        let window = Self.className.withUnsafeBufferPointer { name in
            CreateWindowExW(
                0, name.baseAddress, nil, style, 0, 0, 0, 0, parent, nil, instance,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        hwnd = window
        mailbox.attach(window)
        if let window {
            dpi = max(GetDpiForWindow(window), 96)
        }
    }

    isolated deinit {
        if let hwnd {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            _ = DestroyWindow(hwnd)
        }
    }

    /// The model changed: re-renders when the scene's inputs moved, else just repaints the overlays.
    func modelDidChange() {
        activeModelDidChange()
    }

    private func activeModelDidChange() {
        switch mode {
        case .treemap: treemap.modelDidChange()
        case .sunburst: sunburst.modelDidChange()
        }
    }

    // MARK: - CanvasHost

    var viewSize: CGSize {
        CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale)
    }

    var scale: Double { Double(dpi) / 96 }

    func isShowing(_ presenter: AnyObject) -> Bool {
        guard let hwnd, IsWindowVisible(hwnd) else { return false }
        switch mode {
        case .treemap: return presenter === treemap
        case .sunburst: return presenter === sunburst
        }
    }

    func invalidate() {
        guard let hwnd else { return }
        _ = InvalidateRect(hwnd, nil, false)
    }

    func runInBackground(_ job: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: job)
    }

    func beep() {
        _ = MessageBeep(UINT(MB_OK))
    }

    func screenPoint(for viewPoint: CGPoint) -> POINT {
        var point = POINT(x: LONG((viewPoint.x * scale).rounded()), y: LONG((viewPoint.y * scale).rounded()))
        if let hwnd { _ = ClientToScreen(hwnd, &point) }
        return point
    }

    var showsFocusRing: Bool {
        guard hasFocus, let hwnd else { return false }
        let state = SendMessageW(hwnd, UINT(WM_QUERYUISTATE), 0, 0)
        return state & LRESULT(UISF_HIDEFOCUS) == 0
    }

    // MARK: - Painting

    @discardableResult
    private func ensureDevice() -> Bool {
        if device != nil { return true }
        guard let hwnd else { return false }
        device = D2DCanvas.forWindow(hwnd, pixelWidth: max(pixelWidth, 1), pixelHeight: max(pixelHeight, 1),
                                     dpi: Float(dpi))
        if device != nil {
            activeModelDidChange()
        }
        return device != nil
    }

    /// Draws and presents one frame now.
    func render() {
        guard ensureDevice(), let device else { return }
        let start = ContinuousClock.now
        let covers = mode == .treemap ? treemap.coversCanvas : sunburst.coversCanvas
        guard device.begin(clear: covers ? nil : NDColor(model.vizBackgroundRGB)) else { return }
        let size = viewSize
        switch mode {
        case .treemap: treemap.draw(into: device, size: size)
        case .sunburst: sunburst.draw(into: device, size: size)
        }
        guard device.end(present: presentMode) else {
            deviceLost()
            return
        }
        if timesFrames {
            let name = mode == .treemap ? "frame.treemap" : "frame.sunburst"
            stats.record(name + ".cpu", ms: Clock.milliseconds(since: start))
            device.finish()
            stats.record(name, ms: Clock.milliseconds(since: start))
        }
        if isAnimating { invalidate() }
    }

    var isAnimating: Bool {
        switch mode {
        case .treemap: treemap.isAnimating
        case .sunburst: sunburst.isAnimating
        }
    }

    private func deviceLost() {
        CanvasLog.write("canvas: device lost, rebuilding")
        device = nil
        treemap.deviceLost()
        sunburst.deviceLost()
        ensureDevice()
        invalidate()
    }

    private func resize(width: Int, height: Int) {
        guard width != pixelWidth || height != pixelHeight else { return }
        pixelWidth = width
        pixelHeight = height
        if let device {
            let start = ContinuousClock.now
            if !device.resize(pixelWidth: max(width, 1), pixelHeight: max(height, 1), dpi: Float(dpi)) {
                deviceLost()
            }
            if timesFrames { stats.record("resize.buffers", ms: Clock.milliseconds(since: start)) }
        }
        switch mode {
        case .treemap: treemap.didResize()
        case .sunburst: sunburst.didResize()
        }
        // Paint the stretched frame now, so the window never shows stale buffer edges while dragging.
        render()
    }

    // MARK: - Input

    private func viewPoint(_ lParam: LPARAM) -> CGPoint {
        let x = Int16(truncatingIfNeeded: lParam & 0xFFFF)
        let y = Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)
        return CGPoint(x: Double(x) / scale, y: Double(y) / scale)
    }

    private static func isDown(_ key: Int32) -> Bool {
        GetKeyState(key) < 0
    }

    func pointerMoved(to point: CGPoint?) {
        switch mode {
        case .treemap: treemap.pointerMoved(to: point)
        case .sunburst: sunburst.pointerMoved(to: point)
        }
    }

    private func pointerDown(button: Int, clickCount: Int, at point: CGPoint, wParam: WPARAM) {
        let ctrl = wParam & WPARAM(MK_CONTROL) != 0
        let shift = wParam & WPARAM(MK_SHIFT) != 0
        switch mode {
        case .treemap: treemap.pointerDown(button: button, clickCount: clickCount, at: point, ctrl: ctrl, shift: shift)
        case .sunburst: sunburst.pointerDown(button: button, clickCount: clickCount, at: point, ctrl: ctrl, shift: shift)
        }
    }

    private func wheel(_ wParam: WPARAM, _ lParam: LPARAM, horizontal: Bool) -> Bool {
        guard let hwnd else { return false }
        let delta = Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)
        let keys = wParam & 0xFFFF
        var screen = POINT(
            x: LONG(Int16(truncatingIfNeeded: lParam & 0xFFFF)),
            y: LONG(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF))
        )
        _ = ScreenToClient(hwnd, &screen)
        let point = CGPoint(x: Double(screen.x) / scale, y: Double(screen.y) / scale)
        let notches = Double(delta) / Double(WHEEL_DELTA)
        let ctrl = keys & WPARAM(MK_CONTROL) != 0
        let shift = keys & WPARAM(MK_SHIFT) != 0
        switch mode {
        case .treemap: return treemap.wheel(notches: notches, horizontal: horizontal, at: point, ctrl: ctrl, shift: shift)
        case .sunburst: return sunburst.wheel(notches: notches, horizontal: horizontal, at: point, ctrl: ctrl, shift: shift)
        }
    }

    func keyDown(_ vk: Int32) -> Bool {
        let ctrl = Self.isDown(VK_CONTROL)
        let shift = Self.isDown(VK_SHIFT)
        let alt = Self.isDown(VK_MENU)
        if model.vizHandleKey(vk: UInt32(vk), ctrl: ctrl, shift: shift, alt: alt) { return true }
        guard !alt else { return false }
        switch mode {
        case .treemap: return treemap.keyDown(vk: vk, ctrl: ctrl, shift: shift, alt: alt)
        case .sunburst: return sunburst.keyDown(vk: vk, ctrl: ctrl, shift: shift, alt: alt)
        }
    }

    private func showContextMenu(_ lParam: LPARAM) {
        let x = Int16(truncatingIfNeeded: lParam & 0xFFFF)
        let y = Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)
        var viewPoint: CGPoint?
        var screen = POINT(x: LONG(x), y: LONG(y))
        if x == -1, y == -1 {
            // The menu key or Shift+F10: open at the selection, else the middle.
            let anchor = (mode == .treemap ? treemap.menuAnchor() : sunburst.menuAnchor())
                ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            viewPoint = anchor
            screen = screenPoint(for: anchor)
        } else {
            viewPoint = rightClickPoint
        }
        rightClickPoint = nil
        guard model.selection.primaryID != nil else { return }
        let includeTrash = mode == .treemap ? treemap.menuIncludesTrash(at: viewPoint) : sunburst.menuIncludesTrash(at: viewPoint)
        model.vizShowContextMenu(atScreen: screen, includeTrash: includeTrash)
    }

    // MARK: - Window procedure

    fileprivate func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard let hwnd else { return nil }
        switch Int32(message) {
        case WM_PAINT:
            var paint = PAINTSTRUCT()
            _ = BeginPaint(hwnd, &paint)
            _ = EndPaint(hwnd, &paint)
            render()
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SIZE:
            resize(width: Int(lParam & 0xFFFF), height: Int((lParam >> 16) & 0xFFFF))
            return 0
        case WM_DPICHANGED_AFTERPARENT:
            dpi = max(GetDpiForWindow(hwnd), 96)
            var rect = RECT()
            _ = GetClientRect(hwnd, &rect)
            pixelWidth = 0
            resize(width: Int(rect.right - rect.left), height: Int(rect.bottom - rect.top))
            return 0
        case WM_MOUSEMOVE:
            if !tracksMouseLeave {
                var track = TRACKMOUSEEVENT(
                    cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE),
                    hwndTrack: hwnd, dwHoverTime: 0
                )
                tracksMouseLeave = TrackMouseEvent(&track)
            }
            pointerMoved(to: viewPoint(lParam))
            return 0
        case WM_MOUSELEAVE:
            tracksMouseLeave = false
            pointerMoved(to: nil)
            return 0
        case WM_LBUTTONDOWN:
            _ = SetFocus(hwnd)
            _ = SetCapture(hwnd)
            pointerDown(button: 1, clickCount: 1, at: viewPoint(lParam), wParam: wParam)
            return 0
        case WM_LBUTTONDBLCLK:
            pointerDown(button: 1, clickCount: 2, at: viewPoint(lParam), wParam: wParam)
            return 0
        case WM_LBUTTONUP:
            _ = ReleaseCapture()
            treemap.pointerUp()
            return 0
        case WM_RBUTTONDOWN:
            _ = SetFocus(hwnd)
            rightClickPoint = viewPoint(lParam)
            pointerDown(button: 2, clickCount: 1, at: viewPoint(lParam), wParam: wParam)
            return 0
        case WM_CONTEXTMENU:
            showContextMenu(lParam)
            return 0
        case WM_MOUSEWHEEL:
            return wheel(wParam, lParam, horizontal: false) ? 0 : nil
        case WM_MOUSEHWHEEL:
            return wheel(wParam, lParam, horizontal: true) ? 0 : nil
        case WM_KEYDOWN:
            return keyDown(Int32(wParam)) ? 0 : nil
        case WM_GETDLGCODE:
            var code = LRESULT(DLGC_WANTARROWS | DLGC_WANTCHARS)
            if lParam != 0, let msg = UnsafePointer<MSG>(bitPattern: Int(lParam)),
               msg.pointee.message == UINT(WM_KEYDOWN),
               [VK_RETURN, VK_BACK].contains(Int32(truncatingIfNeeded: msg.pointee.wParam)) {
                code |= LRESULT(DLGC_WANTMESSAGE)
            }
            return code
        case WM_SETFOCUS:
            hasFocus = true
            invalidate()
            return 0
        case WM_KILLFOCUS:
            hasFocus = false
            invalidate()
            return 0
        case WM_UPDATEUISTATE:
            invalidate()
            return nil
        case WM_SHOWWINDOW:
            if wParam != 0 { mailbox.post { [weak self] in self?.activeModelDidChange() } }
            return nil
        case WM_DESTROY:
            device = nil
            mailbox.attach(nil)
            return nil
        default:
            if message == CanvasMailbox.message {
                mailbox.drain()
                return 0
            }
            return nil
        }
    }

    private static func registerClass() {
        guard !isRegistered else { return }
        isRegistered = true
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.style = UINT(CS_DBLCLKS)
            windowClass.lpfnWndProc = canvasWindowProc
            windowClass.hInstance = GetModuleHandleW(nil)
            windowClass.hCursor = LoadCursorW(nil, IDC_ARROW_POINTER)
            windowClass.lpszClassName = name.baseAddress
            _ = RegisterClassExW(&windowClass)
        }
    }
}

/// IDC_ARROW is MAKEINTRESOURCE(32512), which the importer can't express.
nonisolated(unsafe) let IDC_ARROW_POINTER = UnsafePointer<WCHAR>(bitPattern: 32512)

private let canvasWindowProc: WNDPROC = { hwnd, message, wParam, lParam in
    guard let hwnd else { return 0 }
    if message == UINT(WM_NCCREATE),
       let create = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam)) {
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: create.pointee.lpCreateParams)))
    }
    let stored = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
    if stored != 0, let pointer = UnsafeRawPointer(bitPattern: Int(stored)) {
        let canvas = Unmanaged<VizCanvas>.fromOpaque(pointer).takeUnretainedValue()
        let result: LRESULT? = MainActor.assumeIsolated {
            canvas.hwnd == nil && message != UINT(WM_NCCREATE) ? nil : canvas.handle(message, wParam, lParam)
        }
        if let result { return result }
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}
