//
//  SunburstTree.swift
//  SunburstCore
//
//  The minimal tree the sunburst layout reads. Neodisk's FileTreeStore is one
//  conformer (retroactively, in NeodiskUI); a web/wasm demo can conform its own
//  bundled tree. Signatures mirror FileTreeStore's so its conformance is a
//  no-op declaration.
//

/// A tree node the sunburst needs to lay out and color: its size drives the
/// angular span, its directory/package flags decide whether it drills, and its
/// descendant file count sizes the "smaller items" aggregate.
public protocol SunburstNode {
    var id: String { get }
    var name: String { get }
    var isDirectory: Bool { get }
    var isPackage: Bool { get }
    var allocatedSize: Int64 { get }
    var descendantFileCount: Int { get }
    /// This node's cloud-only (dataless) descendant bytes: a dataless file's
    /// logical size, or a directory's cloud-only descendant sum; zero for a
    /// fully-local node. FileNodeRecord already carries it, so its
    /// conformance stays declaration-only.
    var cloudOnlyLogicalSize: Int64 { get }
    /// Whether this leaf is a dataless (cloud-only) file — content lives in
    /// the cloud, ~0 bytes on disk. Always false for directories.
    var isDataless: Bool { get }
    /// The arc's angular weight: `allocatedSize` (on-disk bytes) plus the
    /// cloud-only bytes below when `includingCloudOnly` is on, so the toggle
    /// grows dataless arcs to their full logical size. One definition shared
    /// with the treemap (FileNodeRecord implements it).
    func displayWeight(includingCloudOnly: Bool) -> Int64
}

public extension SunburstNode {
    /// Off-platform conformers (the wasm demo tree) that don't model cloud
    /// files get the on-disk weight and no dataless treatment.
    var cloudOnlyLogicalSize: Int64 { 0 }
    var isDataless: Bool { false }
    func displayWeight(includingCloudOnly: Bool) -> Int64 { allocatedSize }
}

/// Read-only tree access for the layout, grouping, and branch-hue math. The
/// optional `String?` ids and the throwing `children(of:cancellationCheck:)`
/// match FileTreeStore verbatim so its conformance carries no shims.
public protocol SunburstTreeReading {
    associatedtype Node: SunburstNode

    /// The scan root — the drill-independent origin of the color coordinate
    /// system (see `SunburstLayout.colorCoordinate`).
    var rootID: String { get }

    func node(id: String?) -> Node?
    func children(of id: String?) -> [Node]
    func children(
        of id: String?,
        cancellationCheck: () throws -> Void
    ) throws -> [Node]
    func parent(of id: String?) -> Node?
    func path(to id: String?) -> [Node]
    func containsChildren(id: String?) -> Bool
    func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool
}
