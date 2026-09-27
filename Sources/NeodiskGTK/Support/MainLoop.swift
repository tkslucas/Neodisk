//
//  MainLoop.swift
//  NeodiskGTK
//
//  Swift concurrency on GLib's main loop. On Linux the main actor's executor
//  is the main dispatch queue, which libdispatch only drains when someone
//  runs it — normally CoreFoundation's run loop or dispatchMain(). Here GLib
//  owns the main thread instead, so the queue's wake-up eventfd is added to
//  GLib's loop and drained from there: every `Task { @MainActor … }`,
//  `await MainActor.run`, and `DispatchQueue.main.async` then runs on the
//  GTK thread, interleaved with GTK's own events.
//

import CGtk
import Glibc

enum MainLoopBridge {
    /// Installs the bridge; call once, before the application runs.
    static func install() {
        let handle = _dispatch_get_main_queue_handle_4CF()
        g_unix_fd_add(handle, G_IO_IN, { fd, _, _ in
            // The queue pokes an eventfd; reset its counter before draining
            // so the source doesn't fire again for work already handled.
            var counter: UInt64 = 0
            _ = read(fd, &counter, MemoryLayout<UInt64>.size)
            _dispatch_main_queue_callback_4CF(nil)
            return gbool(true)
        }, nil)
    }
}
