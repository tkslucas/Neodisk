// Linux has no getattrlistbulk: readdir plus one fstatat per entry relative to the open directory.
// Emits the same records as the Darwin reader. Read-only: open(O_RDONLY), readdir, fstatat, close.

#if os(Linux)
import Foundation
import Glibc

extension BulkDirectoryReader {
    /// `context` is unused (readdir owns its buffer) but matches the Darwin signature for shared plumbing.
    @discardableResult
    static func readChildren(
        ofDirectory url: URL,
        using context: Context,
        category: ScanSyscallCategory = .traversal,
        cancellationCheck: CancellationCheck,
        onChild: (BulkDirectoryChild) throws -> Void
    ) throws -> Int {
        try cancellationCheck()

        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw BulkDirectoryReadError.openFailed(errno)
        }
        guard let directory = fdopendir(fd) else {
            let openErrno = errno
            close(fd)
            throw BulkDirectoryReadError.openFailed(openErrno)
        }
        // closedir closes `fd` too.
        defer { closedir(directory) }

        var emittedCount = 0
        defer {
            // One "bulk call" per directory: readdir's batching is invisible
            // from here, and the per-entry fstatat calls are the real cost.
            ScanSyscallTally.recordBulkDirectory(category, bulkCalls: 1, entries: emittedCount)
        }

        var directoryDevice: UInt64?
        var directoryStat = stat()
        if fstat(fd, &directoryStat) == 0 {
            directoryDevice = UInt64(directoryStat.st_dev)
        }

        while true {
            try cancellationCheck()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    throw BulkDirectoryReadError.bulkListFailed(errno)
                }
                return emittedCount
            }
            let child: BulkDirectoryChild? = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: 256) { name in
                    if isDotOrDotDot(name) { return nil }
                    return makeChild(
                        name: name,
                        directoryFD: fd,
                        directoryDevice: directoryDevice
                    )
                }
            }
            if let child {
                try onChild(child)
                emittedCount += 1
            }
        }
    }

    private static func isDotOrDotDot(_ name: UnsafePointer<CChar>) -> Bool {
        let dot = CChar(UInt8(ascii: "."))
        guard name[0] == dot else { return false }
        return name[1] == 0 || (name[1] == dot && name[2] == 0)
    }

    /// Like the Darwin reader, an entry that can't be stat'd carries its errno; directories have no sizes.
    private static func makeChild(
        name namePointer: UnsafePointer<CChar>,
        directoryFD: Int32,
        directoryDevice: UInt64?
    ) -> BulkDirectoryChild {
        let name = String(cString: namePointer)
        var status = stat()
        guard fstatat(directoryFD, namePointer, &status, AT_SYMLINK_NOFOLLOW | LinuxStat.noAutomount) == 0 else {
            return BulkDirectoryChild(
                name: name,
                metadata: nil,
                entryErrno: errno,
                isHidden: isHiddenName(name),
                deviceID: directoryDevice,
                directoryMountStatus: 0
            )
        }

        return BulkDirectoryChild(
            name: name,
            metadata: LinuxStat.nodeMetadata(status),
            entryErrno: nil,
            isHidden: isHiddenName(name),
            deviceID: UInt64(status.st_dev),
            // Linux has no per-entry mount status; nested mounts are caught as device changes
            // (MountBoundaryPolicy).
            directoryMountStatus: 0
        )
    }
}

/// Shared by the bulk reader and `ScanMetadataLoader`, so a relisted item matches the full traversal.
nonisolated enum LinuxStat {
    /// AT_NO_AUTOMOUNT, which Swift's Glibc module doesn't import (_GNU_SOURCE-only). A scan must never
    /// fire automounts.
    static let noAutomount: Int32 = 0x800

    /// Directories carry no sizes and link count 1; identity follows the Darwin reader's policy.
    static func nodeMetadata(_ status: stat, isReadable: Bool? = nil, volumeUsedCapacity: Int64? = nil) -> NodeMetadata {
        let fileType = status.st_mode & S_IFMT
        let isDirectory = fileType == S_IFDIR
        let isSymbolicLink = fileType == S_IFLNK
        let linkCount = UInt64(max(status.st_nlink, 1))
        let logicalSize = isDirectory ? 0 : Int64(max(status.st_size, 0))
        // st_blocks is always 512-byte units (stat(2)); reflinked extents are counted per file.
        let allocatedSize = isDirectory ? 0 : Int64(max(status.st_blocks, 0)) * 512
        let lastModified = Date(
            timeIntervalSince1970: Double(status.st_mtim.tv_sec) + Double(status.st_mtim.tv_nsec) / 1_000_000_000
        )
        let capturesIdentity = !isSymbolicLink && (
            isDirectory
                || linkCount > 1
                || allocatedSize >= ScanSizeBaseline.renameTrackingMinimumFileSize
        )
        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: false,
            isSymbolicLink: isSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: lastModified,
            isReadable: isReadable ?? Self.isReadable(status),
            volumeUsedCapacity: volumeUsedCapacity,
            fileIdentity: capturesIdentity
                ? .fileSystem(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
                : nil,
            linkCount: isDirectory ? 1 : linkCount
        )
    }

    /// The scan root gets a precise access(2) readability check (honors ACLs) and its volume's used bytes.
    /// Failures throw POSIX errors.
    static func metadata(for url: URL, includeVolumeDetails: Bool = false) throws -> NodeMetadata {
        try url.withUnsafeFileSystemRepresentation { path -> NodeMetadata in
            guard let path else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: [NSURLErrorKey: url])
            }
            var status = stat()
            guard fstatat(AT_FDCWD, path, &status, AT_SYMLINK_NOFOLLOW | noAutomount) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url]
                )
            }
            guard includeVolumeDetails else { return nodeMetadata(status) }
            var volume = statvfs()
            let volumeUsed: Int64? = statvfs(path, &volume) == 0
                ? Int64(volume.f_blocks - min(volume.f_bfree, volume.f_blocks)) * Int64(volume.f_frsize)
                : nil
            return nodeMetadata(status, isReadable: access(path, R_OK) == 0, volumeUsedCapacity: volumeUsed)
        }
    }

    private static let processCredentials = Credentials()

    /// From mode bits, avoiding an access(2) per entry; ACLs are ignored, so an unreadable directory is
    /// reported when its open fails.
    static func isReadable(_ status: stat) -> Bool {
        let credentials = processCredentials
        if credentials.effectiveUserID == 0 { return true }
        let mode = status.st_mode
        if status.st_uid == credentials.effectiveUserID {
            return mode & S_IRUSR != 0
        }
        if credentials.groupIDs.contains(status.st_gid) {
            return mode & S_IRGRP != 0
        }
        return mode & S_IROTH != 0
    }

    private struct Credentials: Sendable {
        let effectiveUserID: uid_t
        let groupIDs: Set<gid_t>

        init() {
            effectiveUserID = geteuid()
            var groups = Set<gid_t>([getegid()])
            let count = getgroups(0, nil)
            if count > 0 {
                var buffer = [gid_t](repeating: 0, count: Int(count))
                let filled = getgroups(count, &buffer)
                if filled > 0 {
                    groups.formUnion(buffer.prefix(Int(filled)))
                }
            }
            groupIDs = groups
        }
    }
}
#endif
