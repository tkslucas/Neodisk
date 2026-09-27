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
#if canImport(Glibc)
import Glibc
#endif

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

    /// Hidden space: used capacity the scan did not account
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
        #if os(Linux)
        return loadStatvfs(for: url)
        #else
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
        #endif
    }

    #if os(Linux)
    /// Linux has no purgeable space, but ext4 and friends reserve blocks for
    /// root that are neither used nor available to the user. Following df,
    /// "used" is allocated blocks and the capacity is used + available, so
    /// the reserve never reads as used or hidden space and the percentage
    /// matches df's Use% column.
    private static func loadStatvfs(for url: URL) -> VolumeSpaceInfo? {
        var stats = statvfs()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return statvfs(path, &stats)
        }
        guard result == 0, stats.f_blocks > 0 else { return nil }
        let fragmentSize = Int64(stats.f_frsize)
        let used = Int64(stats.f_blocks - min(stats.f_bfree, stats.f_blocks)) * fragmentSize
        let available = Int64(stats.f_bavail) * fragmentSize
        return VolumeSpaceInfo(
            totalCapacity: used + available,
            availableCapacity: available,
            strictlyFreeCapacity: available
        )
    }
    #endif

    /// Assembles the info from raw resource values (separated from `load`
    /// for testability).
    public static func make(
        totalCapacity: Int?,
        availableCapacity: Int?,
        availableCapacityForImportantUsage: Int64?
    ) -> VolumeSpaceInfo? {
        guard let totalCapacity else { return nil }
        let strictlyFree = availableCapacity.map { Int64(max($0, 0)) }
        // Volumes that don't support the important-usage figure report 0
        // there while the plain figure is real — treat 0 as absent.
        let importantUsage = availableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        guard let available = importantUsage ?? strictlyFree else {
            return nil
        }
        return VolumeSpaceInfo(
            totalCapacity: Int64(max(totalCapacity, 0)),
            availableCapacity: available,
            strictlyFreeCapacity: strictlyFree
        )
    }
}
