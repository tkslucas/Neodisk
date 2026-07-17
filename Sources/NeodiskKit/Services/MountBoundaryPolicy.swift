//
//  MountBoundaryPolicy.swift
//  Neodisk
//

import Darwin

/// A scan owns the filesystem containing its explicitly selected root. Child
/// mount points remain visible as zero-child directory records, but traversal
/// does not silently expand into another mounted filesystem. Selecting that
/// mounted directory as the scan root makes its device the owned device and
/// therefore preserves explicit-target behavior.
nonisolated enum MountBoundaryPolicy {
    static let mountPointFlag = UInt32(bitPattern: DIR_MNTSTATUS_MNTPOINT)

    static func isNestedMount(
        deviceID: UInt64?,
        ownedDeviceIDs: Set<UInt64>,
        directoryMountStatus: UInt32
    ) -> Bool {
        if directoryMountStatus & mountPointFlag != 0 {
            return true
        }
        guard let deviceID, !ownedDeviceIDs.isEmpty else {
            // Exotic filesystems may omit ATTR_CMN_DEVID. Preserve their
            // historical fallback behavior instead of guessing a boundary.
            return false
        }
        return !ownedDeviceIDs.contains(deviceID)
    }

    /// The devices a scan rooted at `rootPath` legitimately spans. Usually
    /// just the root's own device — but the startup volume is an APFS volume
    /// group, where the sealed system snapshot at "/" and the Data volume
    /// grafted in via firmlinks can report distinct devices. A "/" scan owns
    /// all of them; treating either as a nested mount would silently drop a
    /// whole volume from the map.
    static func ownedDeviceIDs(rootPath: String, rootDeviceID: UInt64?) -> Set<UInt64> {
        var owned = Set<UInt64>()
        if let rootDeviceID {
            owned.insert(rootDeviceID)
        }
        guard rootPath == "/" else { return owned }
        // "/" covers whichever side of the group the root stat resolved to,
        // "/System" the sealed snapshot, "/System/Volumes/Data" the Data
        // volume. On systems where the group shares one device these
        // collapse into a single entry.
        for path in ["/", "/System", "/System/Volumes/Data"] {
            var status = stat()
            if lstat(path, &status) == 0 {
                // Same widening as the bulk reader's DEVID decode, so set
                // membership compares like with like.
                owned.insert(UInt64(bitPattern: Int64(status.st_dev)))
            }
        }
        return owned
    }
}
