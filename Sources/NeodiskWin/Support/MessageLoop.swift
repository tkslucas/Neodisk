// The UI thread's loop: window messages and the main dispatch queue, so `@MainActor` tasks run between
// messages. Keys the window handles itself (Tab, accelerators) get a look before translation.

import CNeodiskWin
import WinSDK

@MainActor
enum MessageLoop {
    /// Sees every queued message first; true when it was handled.
    static var preTranslate: ((inout MSG) -> Bool)?

    static func run() -> Int32 {
        var handles: [HANDLE?] = [_dispatch_get_main_queue_handle_4CF()]
        var message = MSG()
        while true {
            // QS_ALLINPUT
            let woken = MsgWaitForMultipleObjectsEx(1, &handles, INFINITE, 0x04FF, DWORD(MWMO_INPUTAVAILABLE))
            if woken == 0 {  // WAIT_OBJECT_0: the main queue has work
                drainMainQueue()
            }
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if message.message == UINT(WM_QUIT) {
                    return Int32(truncatingIfNeeded: message.wParam)
                }
                if preTranslate?(&message) == true { continue }
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
        }
    }

    /// Also called from a timer while a modal loop (a window drag, a menu) owns the thread.
    static func drainMainQueue() {
        _dispatch_main_queue_callback_4CF(nil)
    }
}
