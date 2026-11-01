// Volume facts on Windows: which volume holds a path, its file system, drive type and disk kind, and the drive
// letters in use. Read-only queries; the seek-penalty probe opens the volume with no access rights.

#if os(Windows)
import Foundation
import WinSDK

nonisolated enum WindowsVolume {
    /// The root of the volume holding `path` (`C:\`, a mounted folder, `\\server\share\`), with its trailing
    /// backslash, as GetVolumeInformationW and GetDriveTypeW want it.
    static func root(for path: String) -> String? {
        WindowsPath.withWidePath(path) { widePath -> String? in
            var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
            guard GetVolumePathNameW(widePath, &buffer, DWORD(buffer.count)) else { return nil }
            return WindowsPath.string(fromNullTerminated: buffer)
        }
    }

    struct Information {
        /// The 32-bit serial number, the device half of every file identity on the volume.
        let serial: UInt64
        /// Lowercased, like the other platforms' names: `ntfs`, `refs`, `fat32`, `exfat`.
        let fileSystemName: String
    }

    static func information(root: String) -> Information? {
        root.withCString(encodedAs: UTF16.self) { wideRoot -> Information? in
            var serial: DWORD = 0
            var name = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
            guard GetVolumeInformationW(wideRoot, nil, 0, &serial, nil, nil, &name, DWORD(name.count)) else {
                return nil
            }
            return Information(
                serial: UInt64(serial),
                fileSystemName: WindowsPath.string(fromNullTerminated: name).lowercased()
            )
        }
    }

    static func driveType(root: String) -> UINT {
        root.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
    }

    /// Whether the disk under the volume is rotational, from the storage stack's seek-penalty property. Nil when
    /// the stack doesn't say (some virtual and RAID disks).
    static func incursSeekPenalty(root: String) -> Bool? {
        var volumeName = [WCHAR](repeating: 0, count: 64)
        let named = root.withCString(encodedAs: UTF16.self) {
            GetVolumeNameForVolumeMountPointW($0, &volumeName, DWORD(volumeName.count))
        }
        guard named else { return nil }
        // `\\?\Volume{guid}\` names the root directory; without the backslash it names the volume device.
        var device = WindowsPath.string(fromNullTerminated: volumeName)
        if device.hasSuffix("\\") { device.removeLast() }
        let handle = device.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else { return nil }
        defer { CloseHandle(handle) }

        // STORAGE_PROPERTY_QUERY { StorageDeviceSeekPenaltyProperty = 7, PropertyStandardQuery = 0 } and
        // DEVICE_SEEK_PENALTY_DESCRIPTOR { Version, Size, IncursSeekPenalty }, laid out by hand: winioctl.h's
        // CTL_CODE macro and these structs don't import.
        var query: (UInt32, UInt32, UInt32) = (7, 0, 0)
        var descriptor: (UInt32, UInt32, UInt32) = (0, 0, 0)
        var returned: DWORD = 0
        let ioctlStorageQueryProperty: DWORD = 0x002D_1400
        let succeeded = withUnsafeMutableBytes(of: &query) { queryBytes in
            withUnsafeMutableBytes(of: &descriptor) { descriptorBytes in
                DeviceIoControl(
                    handle,
                    ioctlStorageQueryProperty,
                    queryBytes.baseAddress,
                    DWORD(queryBytes.count),
                    descriptorBytes.baseAddress,
                    DWORD(descriptorBytes.count),
                    &returned,
                    nil
                )
            }
        }
        guard succeeded, returned >= 9 else { return nil }
        return descriptor.2 & 0xFF != 0
    }

    /// Every drive letter's root in use (`C:\`, `D:\`).
    static func logicalDriveRoots() -> [String] {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let length = Int(GetLogicalDriveStringsW(DWORD(buffer.count), &buffer))
        guard length > 0, length < buffer.count else { return [] }
        return buffer[..<length].split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
    }
}
#endif
