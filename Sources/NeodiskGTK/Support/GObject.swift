//
//  GObject.swift
//  NeodiskGTK
//
//  The thin layer between Swift and GObject pointers. Swift imports a GTK
//  type whose struct is public (GtkWidget, GtkWindow) as a typed pointer and
//  one whose struct is private (GtkBox, AdwHeaderBar) as OpaquePointer; the
//  app stores every object as a raw pointer and `ptr(_:)` converts at the
//  call site to whichever form the function expects — type inference picks
//  the overload, so GTK calls read like their C originals.
//

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

/// An owned reference to a GObject: sinks a floating reference on adoption
/// and drops it on deinit. Widgets inside a container are owned by the
/// widget tree and are held as plain `GPtr`s; this is for objects the app
/// keeps on its own (list models, textures, detached popovers).
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

/// Attaches a Swift object to a GObject for the GObject's lifetime: the
/// GObject holds one retain on `value`, released when it is finalized.
/// This is how widgets own their Swift controllers without a retain cycle
/// (the controller keeps only an unowned `GPtr` back).
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
