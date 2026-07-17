import Darwin
import Testing
@testable import NeodiskKit

@Suite struct MountBoundaryPolicyTests {
    @Test func mountStatusStopsTraversalEvenOnOwnedDevice() {
        #expect(MountBoundaryPolicy.isNestedMount(
            deviceID: 42,
            ownedDeviceIDs: [42],
            directoryMountStatus: MountBoundaryPolicy.mountPointFlag
        ))
    }

    @Test func foreignDeviceStopsTraversalWhenMountStatusIsUnavailable() {
        #expect(MountBoundaryPolicy.isNestedMount(
            deviceID: 99,
            ownedDeviceIDs: [42],
            directoryMountStatus: 0
        ))
    }

    @Test func anyOwnedDevicePreservesTraversal() {
        // The startup volume group spans two devices; both are owned.
        #expect(!MountBoundaryPolicy.isNestedMount(
            deviceID: 42,
            ownedDeviceIDs: [42, 43],
            directoryMountStatus: 0
        ))
        #expect(!MountBoundaryPolicy.isNestedMount(
            deviceID: 43,
            ownedDeviceIDs: [42, 43],
            directoryMountStatus: 0
        ))
    }

    @Test func unknownDevicesPreserveTraversal() {
        #expect(!MountBoundaryPolicy.isNestedMount(
            deviceID: nil,
            ownedDeviceIDs: [42],
            directoryMountStatus: 0
        ))
        #expect(!MountBoundaryPolicy.isNestedMount(
            deviceID: 99,
            ownedDeviceIDs: [],
            directoryMountStatus: 0
        ))
    }

    @Test func nonRootScanOwnsOnlyItsOwnDevice() {
        #expect(MountBoundaryPolicy.ownedDeviceIDs(
            rootPath: "/Users/someone",
            rootDeviceID: 42
        ) == [42])
    }

    /// A "/" scan must own every device of the startup APFS volume group —
    /// the sealed system snapshot and the firmlinked Data volume. On systems
    /// where the group shares one device this collapses to a single entry;
    /// either way both real devices must be members.
    @Test func startupVolumeScanOwnsSystemAndDataDevices() {
        let owned = MountBoundaryPolicy.ownedDeviceIDs(rootPath: "/", rootDeviceID: nil)
        for path in ["/", "/System", "/System/Volumes/Data", "/Users", "/usr"] {
            var status = stat()
            guard lstat(path, &status) == 0 else { continue }
            #expect(
                owned.contains(UInt64(bitPattern: Int64(status.st_dev))),
                "\(path)'s device must be owned by a startup-volume scan"
            )
        }
    }
}
