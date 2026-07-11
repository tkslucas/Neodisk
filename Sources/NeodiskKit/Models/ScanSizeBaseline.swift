//
//  ScanSizeBaseline.swift
//  Neodisk
//
//  Compact per-node allocated sizes of a previous snapshot — the baseline
//  for "what grew since the last scan" comparisons against the current one.
//

import Foundation

/// Node IDs are stored as 64-bit FNV-1a hashes so a million-node baseline
/// costs ~16 bytes per node instead of retaining every path string; a hash
/// collision (odds around 1e-7 for a two-million-node tree) at worst shows
/// one wrong delta.
///
/// A second, smaller map keys the previous scan's file identities
/// (device+inode, hashed) to their hashed node IDs, so a node that merely
/// moved — same identity at a different path with the same size — diffs
/// against its old entry (delta 0) instead of reading as brand new. Only
/// identity-bearing nodes land in that map (directories and files above
/// `Self.renameTrackingMinimumFileSize` — see BulkDirectoryReader — with
/// linkCount 1), which keeps it a fraction of the size map. Requiring an
/// exact size match on top of the identity hash is the collision guard: a
/// false rename needs a 64-bit hash collision *and* an identical allocated
/// size at a different path.
public struct ScanSizeBaseline: Sendable {
    /// Files below this allocated size don't get their identity captured at
    /// scan time (see BulkDirectoryReader), so renames of smaller files still
    /// read as added+deleted. The threshold keeps snapshots small while
    /// covering every change big enough to matter in a size diff.
    public static let renameTrackingMinimumFileSize: Int64 = 1 << 20

    /// Target the baseline belongs to; deltas against other targets are
    /// meaningless.
    public let targetID: String
    /// When the baseline scan finished, for "changes since …" labels.
    public let finishedAt: Date?
    private let sizeByHashedID: [UInt64: Int64]
    /// Hashed file identity → hashed node ID of the previous scan. Entries
    /// whose identity hash collided within the baseline are poisoned with
    /// `Self.ambiguousHashedID` so they can never produce a false rename.
    private let hashedIDByIdentityHash: [UInt64: UInt64]

    private static let ambiguousHashedID = UInt64.max

    public init(snapshot: ScanSnapshot) {
        targetID = snapshot.target.id
        finishedAt = snapshot.finishedAt
        var sizes = [UInt64: Int64](minimumCapacity: snapshot.treeStore.nodeCount)
        var identities: [UInt64: UInt64] = [:]
        for node in snapshot.treeStore.allNodes {
            let hashedID = Self.hashedID(node.id)
            sizes[hashedID] = node.allocatedSize
            // Hard links share an identity across paths and synthetic nodes
            // have no real file behind them — neither can anchor a rename.
            guard let identity = node.fileIdentity, node.linkCount == 1,
                  !node.isSynthetic else { continue }
            let identityHash = Self.identityHash(identity)
            identities[identityHash] = identities[identityHash] == nil
                ? hashedID
                : Self.ambiguousHashedID
        }
        sizeByHashedID = sizes
        hashedIDByIdentityHash = identities
    }

    /// The allocated size the node had in the baseline scan, or nil when it
    /// didn't exist then (it is new).
    public func allocatedSize(forNodeID id: String) -> Int64? {
        sizeByHashedID[Self.hashedID(id)]
    }

    /// The size the node had at its previous path when it was renamed or
    /// moved since the baseline scan: its identity matches a baseline entry
    /// at a different path with the same allocated size. nil when the node
    /// existed at this path already, carries no identity, or nothing
    /// matches. The same-size requirement makes the answer trivially equal
    /// to `node.allocatedSize`; it exists as the collision guard and so
    /// callers can distinguish "moved" from "new".
    public func movedSourceSize(for node: FileNodeRecord) -> Int64? {
        guard node.linkCount == 1, !node.isSynthetic,
              let identity = node.fileIdentity,
              allocatedSize(forNodeID: node.id) == nil,
              let oldHashedID = hashedIDByIdentityHash[Self.identityHash(identity)],
              oldHashedID != Self.ambiguousHashedID,
              oldHashedID != Self.hashedID(node.id),
              let oldSize = sizeByHashedID[oldHashedID],
              oldSize == node.allocatedSize else { return nil }
        return oldSize
    }

    /// Growth of a node since the baseline scan. A node still at its old
    /// path diffs against that entry; a node that moved (same identity,
    /// different path, same size) diffs against its old entry — delta 0 —
    /// instead of counting its full size as growth; only a genuinely new
    /// node counts everything.
    public func sizeDelta(for node: FileNodeRecord) -> Int64 {
        if let previousSize = allocatedSize(forNodeID: node.id) {
            return node.allocatedSize - previousSize
        }
        if let movedSize = movedSourceSize(for: node) {
            return node.allocatedSize - movedSize
        }
        return node.allocatedSize
    }

    private static func hashedID(_ id: String) -> UInt64 {
        FNV1a.hash(id)
    }

    /// FNV-1a over the identity's bytes: device+inode for filesystem
    /// identities, the raw bytes for resource identifiers.
    static func identityHash(_ identity: FileIdentity) -> UInt64 {
        switch identity {
        case .fileSystem(let device, let inode):
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for value in [device, inode] {
                var bytes = value
                for _ in 0..<8 {
                    hash ^= bytes & 0xff
                    hash &*= 0x0000_0100_0000_01b3
                    bytes >>= 8
                }
            }
            return hash
        case .resourceIdentifier(let data):
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            return hash
        }
    }
}
