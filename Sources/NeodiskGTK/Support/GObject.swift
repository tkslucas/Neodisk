// GTK types with public structs import as typed pointers, private ones as OpaquePointer. Objects are stored
// raw and `ptr(_:)` converts at the call site, so GTK calls read like their C originals.

import CGtk

typealias GPtr = UnsafeMutableRawPointer

@inline(__always) func ptr<T>(_ object: GPtr?) -> UnsafeMutablePointer<T>? {
    object?.assumingMemoryBound(to: T.self)
}

@inline(__always) func ptr(_ object: GPtr?) -> OpaquePointer? {
    object.map(OpaquePointer.init)
}

@inline(__always) func raw<T>(_ object: UnsafeMutablePointer<T>?) -> GPtr? {
    object.map(GPtr.init)
}

@inline(__always) func raw(_ object: OpaquePointer?) -> GPtr? {
    object.map(GPtr.init)
}

/// GLib's boolean.
@inline(__always) func gbool(_ value: Bool) -> gboolean { value ? 1 : 0 }

/// For objects the app keeps itself (list models, textures, detached popovers); the widget tree owns the rest.
final class GObjectRef {
    let pointer: GPtr

    /// Takes ownership of `pointer`, which must carry one reference the
    /// caller owns (a `_new` constructor's return value).
    init(adopting pointer: GPtr) {
        self.pointer = pointer
        if g_object_is_floating(pointer) != 0 {
            g_object_ref_sink(pointer)
        }
    }

    /// Adds a reference to an object someone else owns.
    init(retaining pointer: GPtr) {
        self.pointer = pointer
        g_object_ref_sink(pointer)
    }

    deinit {
        g_object_unref(pointer)
    }
}

/// How widgets own their Swift controllers without a retain cycle (the controller keeps an unowned `GPtr`).
func attach(_ value: AnyObject, to object: GPtr, key: String) {
    g_object_set_data_full(
        ptr(object),
        key,
        Unmanaged.passRetained(value).toOpaque(),
        { data in
            guard let data else { return }
            Unmanaged<AnyObject>.fromOpaque(data).release()
        }
    )
}

func attached<T: AnyObject>(_ type: T.Type, to object: GPtr?, key: String) -> T? {
    guard let object, let data = g_object_get_data(ptr(object), key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(data).takeUnretainedValue() as? T
}

/// A C string argument that may be absent.
func withOptionalCString<Result>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

/// Swift `String` from a GLib-owned C string (not freed).
func string(from cString: UnsafePointer<CChar>?) -> String? {
    cString.map { String(cString: $0) }
}

/// Swift `String` from a newly allocated GLib string, freeing it.
func takeString(_ cString: UnsafeMutablePointer<CChar>?) -> String? {
    guard let cString else { return nil }
    defer { g_free(cString) }
    return String(cString: cString)
}
