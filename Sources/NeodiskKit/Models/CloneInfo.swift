//
//  CloneInfo.swift
//  Neodisk
//
//  APFS clone identity for a scanned file. Files cloned from one another
//  (Finder duplicate, cp -c, clonefile(2)) share on-disk blocks; counting
//  each at its full allocated size over-counts real disk usage, which lets
//  the map's items sum past the volume's Finder-reported used space and
//  swallows the hidden-space figure. Captured only for files the kernel
//  reports as members of a clone family (refCount > 1), so the reference
//  costs nothing on the vast non-cloned majority of nodes.
//

import Foundation

/// Immutable clone-family membership of one file, from the getattrlistbulk
/// extended attributes (ATTR_CMNEXT_CLONEID / ATTR_CMNEXT_CLONE_REFCNT).
/// A class on purpose: an optional reference adds 8 bytes to every
/// FileNodeRecord instead of the ~40 an inline optional struct would, and
/// only clone-family members allocate one.
public final class CloneInfo: Sendable, Equatable, Hashable {
    /// Device the clone ID is scoped to (clone IDs are per-volume).
    public let device: UInt64
    /// Clone family identifier: every member of the family reports the
    /// same value.
    public let cloneID: UInt64
    /// Number of files sharing the family's blocks at capture time.
    public let refCount: UInt32
    /// Bytes unique to this file — not shared with the rest of the family
    /// (ATTR_CMNEXT_PRIVATESIZE). Read during traversal for every member;
    /// nil when it wasn't (single-item metadata, older snapshots), and then
    /// deduplication fetches it for the members it charges.
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

/// The clone families inside a summarized directory (a package or an
/// auto-summarized folder). Those keep no record per file, so without this
/// every clone in them counted at full size: dozens of cloned copies of an
/// app read as dozens of apps. Clone deduplication charges the directory for
/// each member it doesn't keep, as it charges file records; members' private
/// size is 0 (see BulkDirectoryReader), so a charged member costs its whole
/// allocated size. A class for the same reason as `CloneInfo`.
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
