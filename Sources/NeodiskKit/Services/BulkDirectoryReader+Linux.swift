//
//  BulkDirectoryReader+Linux.swift
//  Neodisk
//
//  Linux has no getattrlistbulk: the kernel returns names and types in
//  getdents64 batches (readdir buffers those), and every other attribute
//  costs one fstatat per entry, relative to the already-open directory so no
//  path is resolved twice. This is the same floor du, gdu, and dua sit on;
//  the traversal's parallel directory workers are what hide the per-entry
//  latency. Produces the same `BulkDirectoryChild` records as the Darwin
//  reader, so the engine above it is platform-blind. Read-only by
//  construction: open(O_RDONLY), readdir, fstatat, close.
//

#if os(Linux)
import Foundation
import Glibc

extension BulkDirectoryReader {
    /// Streams decoded records to `onChild`. `context` is unused — readdir
    /// owns its own getdents64 buffer — but the signature matches the Darwin
    /// reader so the traversal's worker plumbing is shared.
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

    /// Mirrors the Darwin reader's per-entry semantics: an entry the kernel
    /// can't stat (vanished mid-listing, permission) comes back with its
    /// errno instead of metadata; directories carry no sizes of their own.
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
            // Nested mounts show up as a device change against the scan's
            // owned devices (MountBoundaryPolicy); Linux has no per-entry
            // mount-status attribute to add to that.
            directoryMountStatus: 0
        )
    }
}

/// Linux stat helpers shared by the scanner's Linux paths: the bulk reader
/// and `ScanMetadataLoader` both turn a `stat` into `NodeMetadata` here, so
/// a relisted or fallback-enumerated item always matches what the full
/// traversal recorded for it.
nonisolated enum LinuxStat {
    /// AT_NO_AUTOMOUNT (fcntl.h, _GNU_SOURCE-only so Swift's Glibc module
    /// doesn't import it): stat an autofs trigger instead of mounting it —
    /// a disk scan must never fire automounts.
    static let noAutomount: Int32 = 0x800

    /// The bulk reader's per-entry rules: directories carry no sizes of
    /// their own and a link count of 1; identity is captured for
    /// directories, multi-link files, and files big enough for rename
    /// tracking (the Darwin reader's policy — see there).
    static func nodeMetadata(_ status: stat, isReadable: Bool? = nil, volumeUsedCapacity: Int64? = nil) -> NodeMetadata {
        let fileType = status.st_mode & S_IFMT
        let isDirectory = fileType == S_IFDIR
        let isSymbolicLink = fileType == S_IFLNK
        let linkCount = UInt64(max(status.st_nlink, 1))
        let logicalSize = isDirectory ? 0 : Int64(max(status.st_size, 0))
        // st_blocks counts 512-byte units regardless of the filesystem's
        // block size (stat(2)); sparse and compressed files report less
        // than their length, reflinked extents are counted per file.
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

    /// One lstat of `url`, converted like a bulk-read entry. The scan root
    /// (`includeVolumeDetails`) asks the kernel for a precise readability
    /// verdict — access(2) honors ACLs — and carries its volume's used bytes
    /// for progress estimation. Failures throw POSIX errors, which
    /// `ScanWarningFactory` classifies like the Darwin loader's.
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

    /// Whether the process may read the object, decided from the mode bits
    /// the fstatat already returned — the equivalent of Darwin's
    /// ATTR_CMN_USERACCESS without an access(2) per entry. ACLs and
    /// capabilities other than root are not consulted; a directory that
    /// turns out unreadable still fails its open and is reported then.
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
