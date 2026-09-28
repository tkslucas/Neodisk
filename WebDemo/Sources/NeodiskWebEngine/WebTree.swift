//
//  WebTree.swift
//  NeodiskWebEngine
//
//  SunburstCore's tree protocols over the flattened index tree, so the real
//  SunburstLayout / colorCoordinate run unchanged. Ids are decimal node
//  indices ("0" is the scan root).
//

import SunburstCore

struct WebNode: SunburstNode {
    let index: Int32

    var id: String { idString(index) }
    var name: String { "" } // labels are resolved JS-side from the index
    var isDirectory: Bool { Tree.isDirectory(index) }
    var isPackage: Bool { Tree.isPackage(index) }
    var allocatedSize: Int64 { Int64(Tree.alloc[Int(index)]) }
    var descendantFileCount: Int { Int(Tree.files[Int(index)]) }
    var cloudOnlyLogicalSize: Int64 { Tree.flag(index, NodeFlags.cloudBytes) ? 1 : 0 }
    var isDataless: Bool { Tree.flag(index, NodeFlags.dataless) }
    /// JS uploads the weight the toolbar's Cloud-Only toggle selects, so the
    /// flag is already folded in.
    func displayWeight(includingCloudOnly: Bool) -> Int64 { Int64(Tree.weight[Int(index)]) }
}

struct WebTree: SunburstTreeReading {
    typealias Node = WebNode

    var rootID: String { "0" }

    private func index(_ id: String?) -> Int32? {
        guard let id, let i = parseID(id), Tree.has(i) else { return nil }
        return i
    }

    func node(id: String?) -> WebNode? {
        index(id).map(WebNode.init(index:))
    }

    func children(of id: String?) -> [WebNode] {
        guard let i = index(id) else { return [] }
        let first = Int(Tree.firstChild[Int(i)])
        let n = Int(Tree.childCount[Int(i)])
        var out: [WebNode] = []
        out.reserveCapacity(n)
        for c in first..<(first + n) { out.append(WebNode(index: Int32(c))) }
        return out
    }

    func children(of id: String?, cancellationCheck: () throws -> Void) throws -> [WebNode] {
        children(of: id)
    }

    func parent(of id: String?) -> WebNode? {
        guard let i = index(id) else { return nil }
        let p = Tree.parent[Int(i)]
        return p >= 0 ? WebNode(index: p) : nil
    }

    func path(to id: String?) -> [WebNode] {
        guard var cur = index(id) else { return [] }
        var out: [WebNode] = []
        while cur >= 0 {
            out.append(WebNode(index: cur))
            cur = Tree.parent[Int(cur)]
        }
        out.reverse()
        return out
    }

    func containsChildren(id: String?) -> Bool {
        guard let i = index(id) else { return false }
        return Tree.childCount[Int(i)] > 0
    }

    func isAncestor(_ ancestorID: String, of descendantID: String?) -> Bool {
        guard let a = index(ancestorID), var cur = index(descendantID) else { return false }
        while cur >= 0 {
            if cur == a { return true }
            cur = Tree.parent[Int(cur)]
        }
        return false
    }
}
