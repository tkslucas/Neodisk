// Small bridges over the Win32 C API: wide strings, message parameter unpacking, and a window base class
// whose procedure dispatches to a Swift object.

import Foundation
import WinSDK

extension String {
    /// NUL-terminated UTF-16, for wide Win32 parameters that outlive one call.
    var wide: [WCHAR] { Array(utf16) + [0] }

    init(wide buffer: UnsafePointer<WCHAR>) {
        var length = 0
        while buffer[length] != 0 { length += 1 }
        self = String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF16.self)
    }

    /// A string from a fixed-size, NUL-terminated wide buffer.
    init(wideBuffer buffer: [WCHAR]) {
        self = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }
}

/// Runs `body` with `string` as a NUL-terminated wide string.
func withWide<Result>(_ string: String, _ body: (UnsafePointer<WCHAR>) -> Result) -> Result {
    string.withCString(encodedAs: UTF16.self, body)
}

func loWord(_ value: WPARAM) -> Int { Int(value & 0xFFFF) }
func hiWord(_ value: WPARAM) -> Int { Int((value >> 16) & 0xFFFF) }
/// Signed client coordinates packed into an LPARAM (GET_X_LPARAM / GET_Y_LPARAM).
func pointFromLParam(_ value: LPARAM) -> (x: Int, y: Int) {
    (Int(Int16(truncatingIfNeeded: value)), Int(Int16(truncatingIfNeeded: value >> 16)))
}

/// Style constants come in as Int32 (or wider when they set the top bit); APIs take DWORD.
func dword<T: BinaryInteger>(_ value: T) -> DWORD { DWORD(truncatingIfNeeded: value) }

/// HKEY_CURRENT_USER: a sign-extended 32-bit constant cast to a handle, which Swift can't import.
nonisolated(unsafe) let hkeyCurrentUser = HKEY(bitPattern: UInt(bitPattern: Int(Int32(bitPattern: 0x8000_0001))))

func isKeyDown(_ virtualKey: Int32) -> Bool {
    GetKeyState(virtualKey) < 0
}

/// A window whose messages reach `handle(_:_:_:)` on the Swift object that created it.
@MainActor
class Win32Window {
    private(set) var hwnd: HWND!

    private static var registeredClasses: Set<String> = []

    static func registerClass(_ name: String, style: UINT = 0, background: HBRUSH? = nil) {
        guard !registeredClasses.contains(name) else { return }
        registeredClasses.insert(name)
        withWide(name) { className in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.style = style
            windowClass.lpfnWndProc = windowProcedure
            windowClass.hInstance = GetModuleHandleW(nil)
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDC_ARROW
            windowClass.hbrBackground = background
            windowClass.lpszClassName = className
            windowClass.hIcon = LoadIconW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1))
            RegisterClassExW(&windowClass)
        }
    }

    /// Creates the window; `handle` starts receiving messages from WM_NCCREATE on.
    func create(
        className: String, title: String = "", style: DWORD, exStyle: DWORD = 0, parent: HWND? = nil,
        x: Int32 = CW_USEDEFAULT, y: Int32 = CW_USEDEFAULT, width: Int32 = CW_USEDEFAULT,
        height: Int32 = CW_USEDEFAULT, id: Int = 0
    ) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        hwnd = withWide(className) { className in
            withWide(title) { title in
                CreateWindowExW(
                    exStyle, className, title, style, x, y, width, height, parent,
                    HMENU(bitPattern: id), GetModuleHandleW(nil), context
                )
            }
        }
    }

    /// The message's result, or nil for the default handling.
    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        nil
    }

    fileprivate func attach(_ hwnd: HWND) {
        self.hwnd = hwnd
    }

    fileprivate func detach() {
        hwnd = nil
    }
}

private let windowProcedure: WNDPROC = { window, message, wParam, lParam in
    // Window procedures run on the thread that created the window: the main one.
    guard let handle = window.map({ Int(bitPattern: $0) }) else { return 0 }
    return MainActor.assumeIsolated {
        let hwnd = HWND(bitPattern: handle)!
        if message == UINT(WM_NCCREATE), let create = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam)),
           let context = create.pointee.lpCreateParams {
            let window = Unmanaged<Win32Window>.fromOpaque(context).takeUnretainedValue()
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: context)))
            window.attach(hwnd)
        }
        guard let pointer = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(hwnd, GWLP_USERDATA))) else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        let window = Unmanaged<Win32Window>.fromOpaque(pointer).takeUnretainedValue()
        if message == UINT(WM_NCDESTROY) {
            _ = window.handle(message, wParam, lParam)
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            window.detach()
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        if let result = window.handle(message, wParam, lParam) {
            return result
        }
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

/// A path as Windows shows it: backslashes, whatever separator the core used.
func displayPath(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: "\\")
}
