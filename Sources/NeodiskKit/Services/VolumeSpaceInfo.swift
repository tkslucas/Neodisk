//
//  VolumeSpaceInfo.swift
//  Neodisk
//
//  The single source of truth for a volume's capacity numbers. Every
//  user-facing total/free/used/hidden figure derives from one of these
//  values, so all surfaces (window title, sunburst legend, sidebar bar and
//  subtitle, status bar) agree with each other and with Finder/Disk Utility.
//

import Foundation

/// A volume's capacity figures, read in one call.
///
/// macOS counts purgeable space (local Time Machine snapshots, caches, swap)
/// toward the space it reports as available in Finder and Disk Utility; that
/// figure is `volumeAvailableCapacityForImportantUsage`. The plain
/// `volumeAvailableCapacity` is the strictly unallocated remainder. Neodisk
/// follows Finder: "available" and "free" mean the important-usage figure,
/// and "used" is capacity minus that.
public struct VolumeSpaceInfo: Equatable, Sendable {
    public let totalCapacity: Int64
    /// Finder-style available space: strictly free plus purgeable
    /// (`volumeAvailableCapacityForImportantUsage`, falling back to the
    /// plain figure when the volume does not report it).
    public let availableCapacity: Int64
    /// Strictly unallocated space (`volumeAvailableCapacity`), when known.
    public let strictlyFreeCapacity: Int64?

    public init(totalCapacity: Int64, availableCapacity: Int64, strictlyFreeCapacity: Int64?) {
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.strictlyFreeCapacity = strictlyFreeCapacity
    }

    /// Space macOS can reclaim on demand: the part of the available figure
    /// that is not strictly free. Zero when the volume reports no distinct
    /// important-usage figure.
    public var purgeableBytes: Int64 {
        max(0, availableCapacity - (strictlyFreeCapacity ?? availableCapacity))
    }

    /// Used space the way Finder and Disk Utility report it: capacity minus
    /// available (purgeable counts as available, not used).
    public var usedBytes: Int64 {
        max(0, totalCapacity - availableCapacity)
    }

    /// DaisyDisk-style hidden space: used capacity the scan did not account
    /// for (unreadable paths, other users' homes, snapshot-held blocks).
    /// Nil when nothing remains — including when the scan over-counts, which
    /// must never surface as negative hidden space.
    public func hiddenSpaceBytes(scannedBytes: Int64) -> Int64? {
        let hidden = usedBytes - scannedBytes
        return hidden > 0 ? hidden : nil
    }

    /// Reads the volume containing `url`. Nil when the volume reports no
    /// total capacity (e.g. some network mounts).
    public static func load(for url: URL) -> VolumeSpaceInfo? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
        } catch {
            return nil
        }
        return make(
            totalCapacity: values.volumeTotalCapacity,
            availableCapacity: values.volumeAvailableCapacity,
            availableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage
        )
    }

    /// Assembles the info from raw resource values (separated from `load`
    /// for testability).
    static func make(
        totalCapacity: Int?,
        availableCapacity: Int?,
        availableCapacityForImportantUsage: Int64?
    ) -> VolumeSpaceInfo? {
        guard let totalCapacity else { return nil }
        let strictlyFree = availableCapacity.map { Int64(max($0, 0)) }
        guard let available = availableCapacityForImportantUsage.map({ max($0, 0) }) ?? strictlyFree else {
            return nil
        }
        return VolumeSpaceInfo(
            totalCapacity: Int64(max(totalCapacity, 0)),
            availableCapacity: available,
            strictlyFreeCapacity: strictlyFree
        )
    }
}
