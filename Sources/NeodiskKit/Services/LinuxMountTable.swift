//
//  LinuxMountTable.swift
//  Neodisk
//
//  /proc/self/mountinfo, parsed. Linux's statfs reports a filesystem magic
//  number and no type name or MNT_LOCAL flag, and FUSE hides the real
//  filesystem behind one magic — the mount table's type strings
//  ("ext4", "nfs4", "fuse.sshfs", "fuseblk") say what the Darwin code gets
//  from f_fstypename. The same table backs the Linux app's volume list.
//

#if os(Linux)
import Foundation
import Glibc

/// One line of /proc/self/mountinfo (proc(5)).
public struct LinuxMount: Sendable, Equatable {
    public let mountID: Int
    public let parentID: Int
    public let deviceMajor: UInt32
    public let deviceMinor: UInt32
    /// The directory of the filesystem mounted here — "/" unless this is a
    /// bind mount or a btrfs subvolume mount.
    public let root: String
    public let mountPoint: String
    public let mountOptions: [String]
    public let fileSystemType: String
    /// The device or remote the filesystem came from ("/dev/nvme0n1p2",
    /// "server:/export", "tmpfs").
    public let source: String

    public var isReadOnly: Bool { mountOptions.contains("ro") }

    /// The filesystem's device number as `stat(2)` reports it in `st_dev`
    /// (glibc's makedev encoding).
    public var deviceID: UInt64 {
        let major = UInt64(deviceMajor)
        let minor = UInt64(deviceMinor)
        return (major & 0xfff) << 8 | (major & ~0xfff) << 32 | (minor & 0xff) | (minor & ~0xff) << 12
    }

    public var fileSystemClass: LinuxFileSystemClass {
        LinuxFileSystemClass(fileSystemType: fileSystemType)
    }
}

/// What a mount's filesystem type means for scanning and for listing it.
public enum LinuxFileSystemClass: Sendable, Equatable {
    /// ext4, btrfs, xfs, ZFS, … — disk-backed, safe to fan out on (when the
    /// device is not rotational).
    case local
    /// FAT, exFAT, NTFS, HFS+, optical media — usually removable or
    /// dual-boot partitions; moderate concurrency.
    case foreign
    /// NFS, SMB, sshfs, … — round trips amplify under fan-out.
    case network
    /// Memory-backed: tmpfs, ramfs, overlay's upper layers.
    case memory
    /// Kernel interfaces with no disk usage to show: proc, sysfs, cgroup,
    /// devtmpfs, squashfs snap images, autofs triggers, …
    case virtual

    public init(fileSystemType type: String) {
        switch type {
        case "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "bcachefs", "zfs", "jfs", "reiserfs", "nilfs2":
            self = .local
        case "vfat", "msdos", "exfat", "ntfs", "ntfs3", "fuseblk", "hfs", "hfsplus", "apfs", "iso9660", "udf":
            self = .foreign
        case "nfs", "nfs4", "cifs", "smb3", "smbfs", "ceph", "afs", "9p", "glusterfs", "lustre", "davfs", "coda":
            self = .network
        case "tmpfs", "ramfs", "overlay":
            self = .memory
        default:
            // FUSE filesystems announce themselves as fuse.<name>; sshfs,
            // rclone, s3fs, gvfs and friends are remote. Block-backed FUSE
            // (ntfs-3g, exfat-fuse) reports "fuseblk", handled above.
            self = type.hasPrefix("fuse") ? .network : .virtual
        }
    }
}

public enum LinuxMountTable {
    /// The calling process's mount table; empty when /proc is unavailable.
    public static func current() -> [LinuxMount] {
        guard let text = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Parses mountinfo text, skipping malformed lines.
    public static func parse(_ text: String) -> [LinuxMount] {
        text.split(separator: "\n").compactMap(parseLine)
    }

    /// The mount whose mount point is the longest path-component prefix of
    /// `path` — the filesystem that path lives on, assuming `path` is already
    /// free of symlinks. Later entries win ties: a mount stacked on the same
    /// point hides the earlier one.
    public static func mount(containing path: String, in mounts: [LinuxMount]) -> LinuxMount? {
        var best: LinuxMount?
        for mount in mounts where isPath(path, under: mount.mountPoint) {
            if best == nil || mount.mountPoint.count >= best!.mountPoint.count {
                best = mount
            }
        }
        return best
    }

    /// The type string the scanner gets from `f_fstypename` on Darwin.
    static func fileSystemType(forPath path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return mount(containing: resolved, in: current())?.fileSystemType
    }

    private static func isPath(_ path: String, under mountPoint: String) -> Bool {
        if mountPoint == "/" { return path.hasPrefix("/") }
        return path == mountPoint || path.hasPrefix(mountPoint + "/")
    }

    private static func parseLine(_ line: Substring) -> LinuxMount? {
        // 36 35 98:0 /mnt1 /mnt2 rw,noatime master:1 - ext3 /dev/root rw
        // A variable run of optional fields ends at the lone "-".
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let separator = fields.firstIndex(of: "-"),
              separator >= 6, fields.count >= separator + 3,
              let mountID = Int(fields[0]),
              let parentID = Int(fields[1]) else {
            return nil
        }
        let device = fields[2].split(separator: ":")
        guard device.count == 2,
              let major = UInt32(device[0]),
              let minor = UInt32(device[1]) else {
            return nil
        }
        return LinuxMount(
            mountID: mountID,
            parentID: parentID,
            deviceMajor: major,
            deviceMinor: minor,
            root: unescape(fields[3]),
            mountPoint: unescape(fields[4]),
            mountOptions: fields[5].split(separator: ",").map(String.init),
            fileSystemType: unescape(fields[separator + 1]),
            source: unescape(fields[separator + 2])
        )
    }

    /// The kernel writes space, tab, newline, and backslash in paths as
    /// three-digit octal escapes (\040 for space).
    static func unescape(_ field: Substring) -> String {
        guard field.contains("\\") else { return String(field) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(field.utf8.count)
        let utf8 = Array(field.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "\\"), let value = octalByte(utf8, at: index + 1) {
                bytes.append(value)
                index += 4
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func octalByte(_ utf8: [UInt8], at start: Int) -> UInt8? {
        guard start + 3 <= utf8.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<3 {
            let digit = utf8[start + offset]
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "7") else { return nil }
            value = value * 8 + UInt32(digit - UInt8(ascii: "0"))
        }
        return value <= 0xFF ? UInt8(value) : nil
    }
}
#endif
