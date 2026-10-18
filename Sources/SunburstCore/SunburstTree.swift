// The minimal tree the sunburst layout reads; signatures mirror FileTreeStore's so its conformance is a no-op.

/// Descendant file count sizes the "smaller items" aggregate.
public protocol SunburstNode {
    var id: String { get }
    var name: String { get }
    var isDirectory: Bool { get }
    var isPackage: Bool { get }
    var allocatedSize: Int64 { get }
    var descendantFileCount: Int { get }
    /// A dataless file's logical size, or a directory's cloud-only descendant sum.
    var cloudOnlyLogicalSize: Int64 { get }
    /// Whether this leaf is a dataless (cloud-only) file — content lives in
    /// the cloud, ~0 bytes on disk. Always false for directories.
    var isDataless: Bool { get }
    /// Shared with the treemap (FileNodeRecord implements it).
    func displayWeight(includingCloudOnly: Bool) -> Int64
}

public extension SunburstNode {
    /// Off-platform conformers (the wasm demo tree) that don't model cloud
    /// files get the on-disk weight and no dataless treatment.
    var cloudOnlyLogicalSize: Int64 { 0 }
    var isDataless: Bool { false }
    func displayWeight(includingCloudOnly: Bool) -> Int64 { allocatedSize }
}

/// Optional ids and the throwing `children(of:cancellationCheck:)` match FileTreeStore so it needs no shims.
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
