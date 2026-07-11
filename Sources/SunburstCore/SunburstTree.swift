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
}

/// Read-only tree access for the layout, grouping, and branch-hue math. The
/// optional `String?` ids and the throwing `children(of:cancellationCheck:)`
/// match FileTreeStore verbatim so its conformance carries no shims.
public protocol SunburstTreeReading {
    associatedtype Node: SunburstNode

    /// The scan root — the drill-independent origin the branch-hue families
    /// derive from (see `SunburstLayout.topLevelBranchID`).
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
