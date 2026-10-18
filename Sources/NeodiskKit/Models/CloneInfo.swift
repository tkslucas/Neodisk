// APFS clones share blocks, so counting each at full size sums past the volume's used space. Captured only
// for clone-family members (refCount > 1), costing nothing on other nodes.

import Foundation

/// A class on purpose: an optional reference adds 8 bytes per FileNodeRecord instead of ~40 for an
/// inline optional struct.
public final class CloneInfo: Sendable, Equatable, Hashable {
    /// Device the clone ID is scoped to (clone IDs are per-volume).
    public let device: UInt64
    /// Clone family identifier: every member of the family reports the
    /// same value.
    public let cloneID: UInt64
    /// Number of files sharing the family's blocks at capture time.
    public let refCount: UInt32
    /// ATTR_CMNEXT_PRIVATESIZE. Nil when not read (single-item metadata, older snapshots); dedup then fetches it.
    public let privateSize: Int64?

    public init(device: UInt64, cloneID: UInt64, refCount: UInt32, privateSize: Int64? = nil) {
        self.device = device
        self.cloneID = cloneID
        self.refCount = refCount
        self.privateSize = privateSize
    }

    public var familyKey: CloneFamilyKey {
        CloneFamilyKey(device: device, cloneID: cloneID)
    }

    public func withPrivateSize(_ privateSize: Int64?) -> CloneInfo {
        CloneInfo(device: device, cloneID: cloneID, refCount: refCount, privateSize: privateSize)
    }

    public static func == (lhs: CloneInfo, rhs: CloneInfo) -> Bool {
        lhs.device == rhs.device
            && lhs.cloneID == rhs.cloneID
            && lhs.refCount == rhs.refCount
            && lhs.privateSize == rhs.privateSize
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(cloneID)
    }
}

public struct CloneFamilyKey: Hashable, Sendable {
    public let device: UInt64
    public let cloneID: UInt64
}

extension CloneFamilyKey: Comparable {
    public static func < (lhs: CloneFamilyKey, rhs: CloneFamilyKey) -> Bool {
        lhs.device == rhs.device ? lhs.cloneID < rhs.cloneID : lhs.device < rhs.device
    }
}

/// One clone-family member found inside a summarized directory, before the
/// summary folds its members into per-family tallies.
nonisolated struct SummarizedCloneMember: Sendable {
    let familyKey: CloneFamilyKey
    let allocatedSize: Int64
}

/// A clone family's members inside one summarized directory.
public struct SummarizedCloneFamily: Sendable, Equatable {
    public let familyKey: CloneFamilyKey
    public let memberCount: UInt32
    /// The members' allocated sizes, summed.
    public let totalSize: Int64
    /// What the family keeps when this directory holds its first member.
    public let largestSize: Int64
    /// Bytes clone deduplication currently takes off the directory for this
    /// family, so a rebalance can move the directory by the difference.
    public let charge: Int64

    public init(familyKey: CloneFamilyKey, memberCount: UInt32, totalSize: Int64, largestSize: Int64, charge: Int64 = 0) {
        self.familyKey = familyKey
        self.memberCount = memberCount
        self.totalSize = totalSize
        self.largestSize = largestSize
        self.charge = charge
    }

    /// The charge when this directory holds the family's first member (it
    /// keeps one copy) or doesn't (every member is shared with that one).
    func charge(holdsFirstMember: Bool) -> Int64 {
        holdsFirstMember ? totalSize - largestSize : totalSize
    }

    func withCharge(_ charge: Int64) -> SummarizedCloneFamily {
        SummarizedCloneFamily(
            familyKey: familyKey,
            memberCount: memberCount,
            totalSize: totalSize,
            largestSize: largestSize,
            charge: charge
        )
    }
}

/// Summarized directories keep no per-file records, so without this cloned copies counted at full size.
/// Members' private size is 0, so a charged member costs its whole allocated size.
public final class SummarizedClones: Sendable, Equatable {
    /// Sorted by family key.
    public let families: [SummarizedCloneFamily]

    public init(families: [SummarizedCloneFamily]) {
        self.families = families
    }

    /// Folds members into per-family tallies; nil without any.
    nonisolated static func make(members: [SummarizedCloneMember]) -> SummarizedClones? {
        guard !members.isEmpty else { return nil }
        var tallies: [CloneFamilyKey: (count: UInt32, total: Int64, largest: Int64)] = [:]
        for member in members {
            var tally = tallies[member.familyKey] ?? (0, 0, 0)
            tally.count &+= 1
            tally.total = tally.total.addingClamped(member.allocatedSize)
            tally.largest = max(tally.largest, member.allocatedSize)
            tallies[member.familyKey] = tally
        }
        let families = tallies
            .map { key, tally in
                SummarizedCloneFamily(
                    familyKey: key,
                    memberCount: tally.count,
                    totalSize: tally.total,
                    largestSize: tally.largest
                )
            }
            .sorted { $0.familyKey < $1.familyKey }
        return SummarizedClones(families: families)
    }

    public static func == (lhs: SummarizedClones, rhs: SummarizedClones) -> Bool {
        lhs.families == rhs.families
    }
}
