// A custom-drawn child window: Direct2D painting through CNeodiskWin, hover and press tracking, keyboard
// focus over its own elements, and a UI Automation provider built from the same element list it hit-tests,
// so what Narrator reads is what's on screen.

import CNeodiskWin
import Foundation
import WinSDK

/// Whether focus visuals show: after keyboard navigation, not after a click (as the system does).
@MainActor
enum FocusCues {
    static var keyboard = false
}

@MainActor
class SurfaceView: Win32Window {
    struct Element {
        var id: Int32
        var parent: Int32 = 0
        var role: NdwRole
        var name: String
        var help: String?
        var automationID: String?
        /// In DIPs, relative to the view.
        var frame: CGRect
        var focusable = false
        var selected = false
        var enabled = true
        var hidden = false
        var value: Double = 0
        /// Clicks and keys reach `activate`.
        var interactive = true
    }

    static let className = "NeodiskSurface"

    private var surface: OpaquePointer?
    private var a11y: OpaquePointer?
    private var tracksLeave = false
    private(set) var hoveredID: Int32?
    private(set) var pressedID: Int32?
    var focusedID: Int32? {
        didSet {
            guard focusedID != oldValue else { return }
            invalidate()
            refreshAccessibility()
            if hasFocus, let focusedID, let a11y { ndw_a11y_focus_changed(a11y, focusedID) }
        }
    }
    /// Called with true when Tab should leave this view for the next one, false for the previous.
    var onTabOut: ((Bool) -> Void)?

    init(parent: HWND, role: NdwRole, name: String) {
        super.init()
        Self.registerClass(Self.className, style: UINT(CS_DBLCLKS))
        create(
            className: Self.className,
            title: name,
            style: dword(WS_CHILD) | dword(WS_VISIBLE) | dword(WS_CLIPSIBLINGS),
            parent: parent, x: 0, y: 0, width: 0, height: 0
        )
        surface = ndw_surface_create(hwnd)
        let context = Unmanaged.passUnretained(self).toOpaque()
        a11y = ndw_a11y_create(hwnd, NdwA11yCallbacks(
            context: context,
            invoke: { context, id in
                let address = Int(bitPattern: context)
                // UI Automation waits on the call: act after it returns.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { SurfaceView.from(address)?.activate(id, fromKeyboard: true) }
                }
            },
            focus: { context, id in
                let address = Int(bitPattern: context)
                MainActor.assumeIsolated {
                    guard let view = SurfaceView.from(address) else { return }
                    SetFocus(view.hwnd)
                    view.focusedID = id
                }
            }
        ))
        let units = Array(name.utf16)
        units.withUnsafeBufferPointer { ndw_a11y_set_root(a11y, Int32(role.rawValue), $0.baseAddress, Int32($0.count)) }
    }

    /// The view behind a callback context: an unretained pointer, valid while the window exists.
    fileprivate static func from(_ address: Int) -> SurfaceView? {
        UnsafeRawPointer(bitPattern: address).map { Unmanaged<SurfaceView>.fromOpaque($0).takeUnretainedValue() }
    }

    // MARK: - For subclasses

    func elements() -> [Element] { [] }
    func draw(_ g: Gfx) {}
    func activate(_ id: Int32, fromKeyboard: Bool) {}
    /// Keys other than Space, Enter and Tab; true when handled.
    func keyDown(_ virtualKey: Int32) -> Bool { false }

    /// The elements Tab stops on, in order.
    func tabStops() -> [Int32] {
        elements().filter { $0.focusable && $0.enabled && !$0.hidden }.map(\.id)
    }

    // MARK: - State

    var scale: Float { WindowMetrics.scale(for: hwnd) }
    var theme: Theme { Theme.current }
    var hasFocus: Bool { GetFocus() == hwnd }
    var showsFocusRing: Bool { hasFocus && FocusCues.keyboard }

    var bounds: CGRect {
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let s = Double(scale)
        return CGRect(x: 0, y: 0, width: Double(rect.right) / s, height: Double(rect.bottom) / s)
    }

    func invalidate() {
        guard let hwnd else { return }
        InvalidateRect(hwnd, nil, false)
    }

    func setFrame(_ frame: CGRect, scale: Float) {
        let s = Double(scale)
        let x = Int32((frame.minX * s).rounded()), y = Int32((frame.minY * s).rounded())
        let right = Int32((frame.maxX * s).rounded()), bottom = Int32((frame.maxY * s).rounded())
        SetWindowPos(hwnd, nil, x, y, right - x, bottom - y, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    /// Takes focus, on the first tab stop or the last.
    func focusFromTab(forward: Bool) {
        let stops = tabStops()
        if focusedID == nil || !stops.contains(focusedID!) {
            focusedID = forward ? stops.first : stops.last
        }
        SetFocus(hwnd)
    }

    /// Tab inside the view; false at the end, where focus should leave.
    func moveFocus(forward: Bool) -> Bool {
        let stops = tabStops()
        guard let current = focusedID, let index = stops.firstIndex(of: current) else { return false }
        let next = forward ? index + 1 : index - 1
        guard stops.indices.contains(next) else { return false }
        focusedID = stops[next]
        return true
    }

    func refreshAccessibility() {
        guard let a11y else { return }
        let list = elements()
        let s = Double(scale)
        // One buffer holds every string, so the C side can copy them in a single call.
        var text: [UInt16] = []
        var ranges: [(name: Range<Int>, help: Range<Int>, automationID: Range<Int>)] = []
        for element in list {
            let nameStart = text.count
            text += element.name.utf16
            let helpStart = text.count
            text += (element.help ?? "").utf16
            let idStart = text.count
            text += (element.automationID ?? "").utf16
            ranges.append((nameStart..<helpStart, helpStart..<idStart, idStart..<text.count))
        }
        let focused = hasFocus ? focusedID : nil
        text.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress
            let nodes = zip(list, ranges).map { element, range in
                var flags: Int32 = 0
                if element.focusable { flags |= Int32(NDW_NODE_FOCUSABLE) }
                if element.id == focused { flags |= Int32(NDW_NODE_FOCUSED) }
                if element.selected { flags |= Int32(NDW_NODE_SELECTED) }
                if !element.enabled { flags |= Int32(NDW_NODE_DISABLED) }
                if element.hidden { flags |= Int32(NDW_NODE_HIDDEN) }
                return NdwA11yNode(
                    id: element.id, parent: element.parent, role: Int32(element.role.rawValue), flags: flags,
                    rect: NdwRect(
                        x: Float(element.frame.minX * s), y: Float(element.frame.minY * s),
                        w: Float(element.frame.width * s), h: Float(element.frame.height * s)
                    ),
                    name: base.map { $0 + range.name.lowerBound }, name_length: Int32(range.name.count),
                    help: base.map { $0 + range.help.lowerBound }, help_length: Int32(range.help.count),
                    automation_id: base.map { $0 + range.automationID.lowerBound },
                    automation_id_length: Int32(range.automationID.count),
                    value: element.value
                )
            }
            nodes.withUnsafeBufferPointer { ndw_a11y_set_nodes(a11y, $0.baseAddress, Int32($0.count)) }
        }
    }

    func announceValueChange(_ id: Int32) {
        if let a11y { ndw_a11y_value_changed(a11y, id) }
    }

    private func hit(_ lParam: LPARAM) -> Element? {
        let (x, y) = pointFromLParam(lParam)
        let s = Double(scale)
        let point = CGPoint(x: Double(x) / s, y: Double(y) / s)
        return elements().last { $0.interactive && !$0.hidden && $0.enabled && $0.frame.contains(point) }
    }

    // MARK: - Messages

    override func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(truncatingIfNeeded: message) {
        case WM_PAINT:
            var paint = PAINTSTRUCT()
            let dc = BeginPaint(hwnd, &paint)
            let dirty = paint.rcPaint
            if let surface, let raw = ndw_surface_begin(
                surface, dc, dirty.left, dirty.top, dirty.right - dirty.left, dirty.bottom - dirty.top
            ) {
                draw(Gfx(raw: raw, scale: scale))
                ndw_surface_end(surface)
            }
            EndPaint(hwnd, &paint)
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SIZE:
            invalidate()
            refreshAccessibility()
            return 0
        case WM_MOUSEMOVE:
            if !tracksLeave {
                var track = TRACKMOUSEEVENT(
                    cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE),
                    hwndTrack: hwnd, dwHoverTime: 0
                )
                TrackMouseEvent(&track)
                tracksLeave = true
            }
            let id = hit(lParam)?.id
            if id != hoveredID {
                hoveredID = id
                invalidate()
            }
            return 0
        case WM_MOUSELEAVE:
            tracksLeave = false
            if hoveredID != nil {
                hoveredID = nil
                invalidate()
            }
            return 0
        case WM_LBUTTONDOWN, WM_LBUTTONDBLCLK:
            FocusCues.keyboard = false
            guard let element = hit(lParam) else { return 0 }
            pressedID = element.id
            SetCapture(hwnd)
            if element.focusable {
                focusedID = element.id
                SetFocus(hwnd)
            }
            invalidate()
            return 0
        case WM_LBUTTONUP:
            let pressed = pressedID
            pressedID = nil
            ReleaseCapture()
            invalidate()
            if let pressed, hit(lParam)?.id == pressed {
                activate(pressed, fromKeyboard: false)
            }
            return 0
        case WM_CAPTURECHANGED:
            if pressedID != nil {
                pressedID = nil
                invalidate()
            }
            return 0
        case WM_SETFOCUS:
            if focusedID == nil { focusedID = tabStops().first }
            invalidate()
            refreshAccessibility()
            if let focusedID, let a11y { ndw_a11y_focus_changed(a11y, focusedID) }
            return 0
        case WM_KILLFOCUS:
            invalidate()
            refreshAccessibility()
            return 0
        case WM_GETDLGCODE:
            return LRESULT(DLGC_WANTARROWS | DLGC_WANTCHARS)
        case WM_KEYDOWN:
            let key = Int32(truncatingIfNeeded: wParam)
            if key == VK_SPACE || key == VK_RETURN, let focusedID {
                FocusCues.keyboard = true
                activate(focusedID, fromKeyboard: true)
                return 0
            }
            if keyDown(key) {
                FocusCues.keyboard = true
                invalidate()
                return 0
            }
            return nil
        case WM_GETOBJECT:
            var result: Int = 0
            if let a11y, ndw_a11y_get_object(a11y, UInt(wParam), Int(lParam), &result) != 0 {
                return LRESULT(result)
            }
            return nil
        case WM_DESTROY:
            if let a11y { ndw_a11y_destroy(a11y) }
            a11y = nil
            if let surface { ndw_surface_destroy(surface) }
            surface = nil
            return nil
        default:
            if let a11y, ndw_a11y_handle_message(a11y, message, UInt(wParam), Int(lParam)) != 0 { return 0 }
            return nil
        }
    }
}

@MainActor
enum WindowMetrics {
    /// NEODISK_SCALE multiplies the window's DPI scale, to check layouts at 150 % or 200 % on a 100 % display.
    static let scaleOverride: Float = ProcessInfo.processInfo.environment["NEODISK_SCALE"].flatMap(Float.init) ?? 1

    static func scale(for hwnd: HWND?) -> Float {
        guard let hwnd else { return scaleOverride }
        let dpi = GetDpiForWindow(hwnd)
        return Float(dpi == 0 ? 96 : dpi) / 96 * scaleOverride
    }
}
