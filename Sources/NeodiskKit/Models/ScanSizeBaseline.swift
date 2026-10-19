// Compact per-node allocated sizes of a previous snapshot — the baseline
// for "what grew since the last scan" comparisons against the current one.

import Foundation

/// Node IDs are FNV-1a hashes (~16 bytes per node); a collision at worst shows one wrong delta. A smaller
/// identity map lets a moved node (same identity and size) diff as delta 0 instead of reading as new.
public struct ScanSizeBaseline: Sendable {
    /// Smaller files' identities aren't captured, so their renames read as added plus deleted.
    public static let renameTrackingMinimumFileSize: Int64 = 1 << 20

    /// Target the baseline belongs to; deltas against other targets are
    /// meaningless.
    public let targetID: String
    /// When the baseline scan finished, for "changes since …" labels.
    public let finishedAt: Date?
    private let sizeByHashedID: [UInt64: Int64]
    /// Identity hashes that collided are poisoned with `Self.ambiguousHashedID` so they never fake a rename.
    private let hashedIDByIdentityHash: [UInt64: UInt64]

    private static let ambiguousHashedID = UInt64.max

    public init(snapshot: ScanSnapshot) {
        targetID = snapshot.target.id
        finishedAt = snapshot.finishedAt
        var sizes = [UInt64: Int64](minimumCapacity: snapshot.treeStore.nodeCount)
        var identities: [UInt64: UInt64] = [:]
        for node in snapshot.treeStore.allNodes {
            if Task.isCancelled { break }
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

    /// The same-size requirement makes the answer equal `node.allocatedSize`; it exists as the collision guard
    /// and to tell "moved" from "new".
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

    /// A moved node diffs against its old entry (delta 0); only a genuinely new node counts its full size.
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
