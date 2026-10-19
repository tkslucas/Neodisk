#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Child mount points stay visible as zero-child records but are never expanded; selecting one as the root
/// makes its device the owned one.
nonisolated enum MountBoundaryPolicy {
    #if canImport(Darwin)
    static let mountPointFlag = UInt32(bitPattern: DIR_MNTSTATUS_MNTPOINT)
    #else
    /// Darwin's DIR_MNTSTATUS_MNTPOINT bit. The Linux reader never sets it:
    /// there, nested mounts show up only as a device change.
    static let mountPointFlag: UInt32 = 0x0000_0001
    #endif

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

    /// The startup volume group's sealed system and Data volumes can report distinct devices; a "/" scan owns
    /// all of them, or a whole volume would drop from the map.
    static func ownedDeviceIDs(rootPath: String, rootDeviceID: UInt64?) -> Set<UInt64> {
        var owned = Set<UInt64>()
        if let rootDeviceID {
            owned.insert(rootDeviceID)
        }
        #if os(macOS)
        guard rootPath == "/" else { return owned }
        // "/" is whichever side the root stat resolved to; these collapse when the group shares one device.
        for path in ["/", "/System", "/System/Volumes/Data"] {
            var status = stat()
            if lstat(path, &status) == 0 {
                // Same widening as the bulk reader's DEVID decode, so set
                // membership compares like with like.
                owned.insert(UInt64(bitPattern: Int64(status.st_dev)))
            }
        }
        #endif
        return owned
    }
}
