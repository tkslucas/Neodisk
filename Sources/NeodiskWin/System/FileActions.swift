// File Explorer and the clipboard.

import Foundation
import WinSDK

enum FileActions {
    /// Opens File Explorer with `path` selected.
    static func showInExplorer(_ path: String) {
        let arguments = "/select,\"\(displayPath(path))\""
        _ = withWide("explorer.exe") { file in
            withWide(arguments) { ShellExecuteW(nil, nil, file, $0, nil, SW_SHOWNORMAL) }
        }
    }

    /// Opens the item with its default app (a folder in File Explorer).
    static func open(_ path: String) {
        _ = withWide(displayPath(path)) { ShellExecuteW(nil, nil, $0, nil, nil, SW_SHOWNORMAL) }
    }

    static func copyToClipboard(_ text: String, owner: HWND?) {
        guard OpenClipboard(owner) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let units = text.wide
        let bytes = units.count * MemoryLayout<WCHAR>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)), let target = GlobalLock(memory) else { return }
        units.withUnsafeBytes { target.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        SetClipboardData(UINT(CF_UNICODETEXT), memory)
    }
}
