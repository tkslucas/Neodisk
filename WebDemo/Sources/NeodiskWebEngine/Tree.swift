//
//  Tree.swift
//  NeodiskWebEngine
//
//  The flattened scan tree JS hands the engine through shared linear-memory
//  buffers (no per-node JS↔wasm calls). Node 0 is the scan root; every
//  node's children occupy a contiguous index range (breadth-first order),
//  sorted by weight descending exactly like FileTreeStore.children(of:).
//
//  Per-node columns (all `count` long):
//    parent      Int32    parent index, -1 for the root
//    firstChild  Int32    index of the first child
//    childCount  Int32    number of children (0 for files/packages)
//    weight      Float64  display weight (allocated + cloud-only bytes when
//                         the toolbar's Cloud-Only toggle is on)
//    alloc       Float64  on-disk bytes (allocatedSize)
//    files       Float64  descendant file count (aggregate "N items")
//    flags       UInt32   NodeFlags below
//    rgb         Float32×3 kind/age fill resolved by JS (palette.js); unused
//                         in branch mode, where the engine computes hues
//

struct NodeFlags {
    static let directory: UInt32 = 1 << 0
    /// Opaque package (.app, .photoslibrary): a directory drawn as one item.
    static let package: UInt32 = 1 << 1
    /// Dataless (cloud-only) file.
    static let dataless: UInt32 = 1 << 2
    /// allocatedSize == 0.
    static let allocZero: UInt32 = 1 << 3
    /// cloudOnlyLogicalSize > 0 (the node or its subtree has cloud-only bytes).
    static let cloudBytes: UInt32 = 1 << 4
    /// The user clicked this folder's "smaller items" cell open.
    static let aggregateExpanded: UInt32 = 1 << 5
    /// Stays at full color under the active highlight (TreemapScene.matches).
    static let highlightMatch: UInt32 = 1 << 6
}

enum Tree {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var capacity = 0
    nonisolated(unsafe) static var parent = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    nonisolated(unsafe) static var firstChild = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    nonisolated(unsafe) static var childCount = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    nonisolated(unsafe) static var weight = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    nonisolated(unsafe) static var alloc = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    nonisolated(unsafe) static var files = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    nonisolated(unsafe) static var flags = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    nonisolated(unsafe) static var rgb = UnsafeMutablePointer<Float>.allocate(capacity: 3)

    static func reserve(_ n: Int) {
        if n > capacity {
            parent.deallocate(); firstChild.deallocate(); childCount.deallocate()
            weight.deallocate(); alloc.deallocate(); files.deallocate()
            flags.deallocate(); rgb.deallocate()
            let cap = max(n, 1024)
            parent = .allocate(capacity: cap)
            firstChild = .allocate(capacity: cap)
            childCount = .allocate(capacity: cap)
            weight = .allocate(capacity: cap)
            alloc = .allocate(capacity: cap)
            files = .allocate(capacity: cap)
            flags = .allocate(capacity: cap)
            rgb = .allocate(capacity: cap * 3)
            capacity = cap
        }
        count = n
    }

    @inline(__always) static func has(_ i: Int32) -> Bool { i >= 0 && Int(i) < count }
    @inline(__always) static func isDirectory(_ i: Int32) -> Bool { flags[Int(i)] & NodeFlags.directory != 0 }
    @inline(__always) static func isPackage(_ i: Int32) -> Bool { flags[Int(i)] & NodeFlags.package != 0 }
    @inline(__always) static func flag(_ i: Int32, _ f: UInt32) -> Bool { flags[Int(i)] & f != 0 }
    @inline(__always) static func color(_ i: Int32) -> SIMD3<Float> {
        let o = Int(i) * 3
        return SIMD3(rgb[o], rgb[o + 1], rgb[o + 2])
    }
    /// SunburstLayout.isSunburstFolder: packages are files unless their
    /// contents are in the tree.
    @inline(__always) static func isSunburstFolder(_ i: Int32) -> Bool {
        isDirectory(i) && (!isPackage(i) || childCount[Int(i)] > 0)
    }
    /// Levels below the scan root.
    static func depth(of i: Int32) -> Int {
        var d = 0
        var cur = parent[Int(i)]
        while cur >= 0 {
            d += 1
            cur = parent[Int(cur)]
        }
        return d
    }
}

// MARK: - Decimal node ids (SunburstCore speaks String ids)

func idString(_ value: Int32) -> String {
    if value == 0 { return "0" }
    var v = Int(value)
    var digits: [UInt8] = []
    let negative = v < 0
    if negative { v = -v }
    while v > 0 {
        digits.append(UInt8(48 + v % 10))
        v /= 10
    }
    if negative { digits.append(45) }
    digits.reverse()
    return String(decoding: digits, as: UTF8.self)
}

/// Parses a decimal id (optionally behind a "prefix-" such as "aggregate-").
func parseID(_ id: String) -> Int32? {
    var value = 0
    var sawDigit = false
    for byte in id.utf8 {
        if byte >= 48 && byte <= 57 {
            value = value * 10 + Int(byte - 48)
            sawDigit = true
        } else if byte == 45 { // '-': a prefix separator — restart
            value = 0
            sawDigit = false
        } else if sawDigit {
            return nil
        }
    }
    return sawDigit ? Int32(value) : nil
}
