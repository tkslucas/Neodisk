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
    /// (ATTR_CMNEXT_PRIVATESIZE). Nil until deduplication fetches it for
    /// the family members it charges; the kept member never needs it.
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
