//
//  Signals.swift
//  NeodiskGTK
//
//  Closure-based GObject signal connection. GLib calls C function pointers;
//  each signal *shape* gets one non-capturing @convention(c) trampoline that
//  recovers the Swift closure from the user-data pointer. GLib owns one
//  retain on the closure box and releases it when the handler is
//  disconnected or the instance is finalized, so handlers never outlive
//  their widget and never leak.
//
//  Every handler runs on the main thread, inside GLib's loop, which is the
//  main actor's executor too (see MainLoop.swift).
//

import CGtk

private final class ClosureBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private let releaseClosureBox: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@inline(__always)
private func box<Value>(_ data: GPtr?, as _: Value.Type) -> Value {
    Unmanaged<ClosureBox<Value>>.fromOpaque(data!).takeUnretainedValue().value
}

@discardableResult
private func connectBox<Value>(
    _ instance: GPtr?,
    _ signal: String,
    _ handler: Value,
    _ trampoline: GCallback,
    after: Bool
) -> gulong {
    guard let instance else { return 0 }
    return g_signal_connect_data(
        instance,
        signal,
        trampoline,
        Unmanaged.passRetained(ClosureBox(handler)).toOpaque(),
        releaseClosureBox,
        GConnectFlags(rawValue: after ? 1 : 0)  // G_CONNECT_AFTER
    )
}

// MARK: - Shapes

/// `void handler(GObject*, gpointer)` — clicked, activate, destroy, map, …
@discardableResult
func connect(_ instance: GPtr?, _ signal: String, after: Bool = false, _ handler: @escaping @MainActor () -> Void) -> gulong {
    typealias Handler = @MainActor () -> Void
    let trampoline: @convention(c) (GPtr?, GPtr?) -> Void = { _, data in
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)() }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: after)
}

/// `void handler(GObject*, GParamSpec*, gpointer)` — property change
/// notification. Always use this for `notify::…`: the extra GParamSpec
/// argument means the two-argument shape would read it as the closure.
@discardableResult
func connectNotify(_ instance: GPtr?, _ property: String, _ handler: @escaping @MainActor () -> Void) -> gulong {
    connectPointer(instance, "notify::\(property)") { _ in handler() }
}

/// `gboolean handler(GObject*, gpointer)` — close-request and friends;
/// returning true stops further handlers.
@discardableResult
func connectBool(_ instance: GPtr?, _ signal: String, _ handler: @escaping @MainActor () -> Bool) -> gulong {
    typealias Handler = @MainActor () -> Bool
    let trampoline: @convention(c) (GPtr?, GPtr?) -> gboolean = { _, data in
        nonisolated(unsafe) let data = data
        return MainActor.assumeIsolated { gbool(box(data, as: Handler.self)()) }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `void handler(GObject*, gpointer arg, gpointer)` — notify::prop
/// (GParamSpec*), list-item factory setup/bind (GtkListItem*), row-activated
/// (GtkListBoxRow*), action activate (GVariant*).
@discardableResult
func connectPointer(_ instance: GPtr?, _ signal: String, _ handler: @escaping @MainActor (GPtr?) -> Void) -> gulong {
    typealias Handler = @MainActor (GPtr?) -> Void
    let trampoline: @convention(c) (GPtr?, GPtr?, GPtr?) -> Void = { _, argument, data in
        nonisolated(unsafe) let argument = argument
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)(argument) }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `void handler(GObject*, double x, double y, gpointer)` — motion, enter,
/// drag-begin/update/end.
@discardableResult
func connectPoint(_ instance: GPtr?, _ signal: String, _ handler: @escaping @MainActor (Double, Double) -> Void) -> gulong {
    typealias Handler = @MainActor (Double, Double) -> Void
    let trampoline: @convention(c) (GPtr?, Double, Double, GPtr?) -> Void = { _, x, y, data in
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)(x, y) }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `void handler(GtkGesture*, int n_press, double x, double y, gpointer)` —
/// GtkGestureClick pressed/released.
@discardableResult
func connectPress(_ instance: GPtr?, _ signal: String, _ handler: @escaping @MainActor (Int, Double, Double) -> Void) -> gulong {
    typealias Handler = @MainActor (Int, Double, Double) -> Void
    let trampoline: @convention(c) (GPtr?, Int32, Double, Double, GPtr?) -> Void = { _, presses, x, y, data in
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)(Int(presses), x, y) }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `gboolean handler(GtkEventControllerScroll*, double dx, double dy, gpointer)`.
@discardableResult
func connectScroll(_ instance: GPtr?, _ handler: @escaping @MainActor (Double, Double) -> Bool) -> gulong {
    typealias Handler = @MainActor (Double, Double) -> Bool
    let trampoline: @convention(c) (GPtr?, Double, Double, GPtr?) -> gboolean = { _, dx, dy, data in
        nonisolated(unsafe) let data = data
        return MainActor.assumeIsolated { gbool(box(data, as: Handler.self)(dx, dy)) }
    }
    return connectBox(instance, "scroll", handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `gboolean handler(GtkEventControllerKey*, guint keyval, guint keycode,
/// GdkModifierType state, gpointer)`.
@discardableResult
func connectKey(_ instance: GPtr?, _ handler: @escaping @MainActor (_ keyval: UInt32, _ state: UInt32) -> Bool) -> gulong {
    typealias Handler = @MainActor (UInt32, UInt32) -> Bool
    let trampoline: @convention(c) (GPtr?, UInt32, UInt32, UInt32, GPtr?) -> gboolean = { _, keyval, _, state, data in
        nonisolated(unsafe) let data = data
        return MainActor.assumeIsolated { gbool(box(data, as: Handler.self)(keyval, state)) }
    }
    return connectBox(instance, "key-pressed", handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `void handler(GObject*, double value, gpointer)` — GtkGestureZoom
/// scale-changed.
@discardableResult
func connectDouble(_ instance: GPtr?, _ signal: String, _ handler: @escaping @MainActor (Double) -> Void) -> gulong {
    typealias Handler = @MainActor (Double) -> Void
    let trampoline: @convention(c) (GPtr?, Double, GPtr?) -> Void = { _, value, data in
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)(value) }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `void handler(GObject*, guint position, gpointer)` — GtkListView and
/// GtkColumnView activate.
@discardableResult
func connectPosition(_ instance: GPtr?, _ signal: String, _ handler: @escaping @MainActor (UInt32) -> Void) -> gulong {
    typealias Handler = @MainActor (UInt32) -> Void
    let trampoline: @convention(c) (GPtr?, UInt32, GPtr?) -> Void = { _, position, data in
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)(position) }
    }
    return connectBox(instance, signal, handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `void handler(GtkSelectionModel*, guint position, guint n_items, gpointer)`.
@discardableResult
func connectSelectionChanged(_ instance: GPtr?, _ handler: @escaping @MainActor () -> Void) -> gulong {
    typealias Handler = @MainActor () -> Void
    let trampoline: @convention(c) (GPtr?, UInt32, UInt32, GPtr?) -> Void = { _, _, _, data in
        nonisolated(unsafe) let data = data
        MainActor.assumeIsolated { box(data, as: Handler.self)() }
    }
    return connectBox(instance, "selection-changed", handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

/// `gboolean handler(GtkWidget*, int x, int y, gboolean keyboard_mode,
/// GtkTooltip*, gpointer)`.
@discardableResult
func connectTooltip(_ instance: GPtr?, _ handler: @escaping @MainActor (_ x: Int, _ y: Int, _ tooltip: GPtr?) -> Bool) -> gulong {
    typealias Handler = @MainActor (Int, Int, GPtr?) -> Bool
    let trampoline: @convention(c) (GPtr?, Int32, Int32, gboolean, GPtr?, GPtr?) -> gboolean = { _, x, y, _, tooltip, data in
        nonisolated(unsafe) let tooltip = tooltip
        nonisolated(unsafe) let data = data
        return MainActor.assumeIsolated { gbool(box(data, as: Handler.self)(Int(x), Int(y), tooltip)) }
    }
    return connectBox(instance, "query-tooltip", handler as Handler, unsafeBitCast(trampoline, to: GCallback.self), after: false)
}

// MARK: - Actions

/// Adds a GSimpleAction named `name` to an action map (application or
/// window), optionally taking a string parameter. Returns the action so the
/// caller can toggle its enabled state.
@discardableResult
@MainActor
func addAction(
    to map: GPtr?,
    _ name: String,
    stringParameter: Bool = false,
    _ handler: @escaping @MainActor (String?) -> Void
) -> GPtr? {
    let parameterType = stringParameter ? g_variant_type_new("s") : nil
    defer { if let parameterType { g_variant_type_free(parameterType) } }
    guard let action = raw(g_simple_action_new(name, parameterType)) else { return nil }
    connectPointer(action, "activate") { variant in
        let argument = variant.flatMap { string(from: g_variant_get_string(ptr($0), nil)) }
        handler(argument)
    }
    g_action_map_add_action(ptr(map), ptr(action))
    g_object_unref(action)
    return action
}

@MainActor
func setActionEnabled(_ action: GPtr?, _ enabled: Bool) {
    g_simple_action_set_enabled(ptr(action), gbool(enabled))
}
