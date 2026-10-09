#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import NeodiskKit

/// The Linux platform layer: the readdir+fstatat bulk reader, the lstat
/// metadata path, the mount table, and statvfs capacity. The Darwin
/// counterparts are covered by the suites gated to Apple platforms.
@Suite struct LinuxPlatformTests {
    private func makeDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "neodisk-linux-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readChildren(of url: URL) throws -> [String: BulkDirectoryChild] {
        var children: [String: BulkDirectoryChild] = [:]
        _ = try BulkDirectoryReader.readChildren(
            ofDirectory: url,
            using: BulkDirectoryReader.Context(),
            cancellationCheck: {}
        ) { children[$0.name] = $0 }
        return children
    }

    @Test func bulkEntriesMatchLstatAcrossARealDirectory() throws {
        // A real system directory: shared objects, symlink farms, subdirs.
        let root = URL(filePath: "/usr/lib", directoryHint: .isDirectory)
        let children = try readChildren(of: root)
        #expect(children.count > 10)

        var compared = 0
        for child in children.values.prefix(400) {
            guard let metadata = child.metadata else { continue }
            var status = stat()
            guard lstat(root.appending(path: child.name).path, &status) == 0 else { continue }
            compared += 1
            let type = status.st_mode & S_IFMT
            #expect(metadata.isDirectory == (type == S_IFDIR), "\(child.name)")
            #expect(metadata.isSymbolicLink == (type == S_IFLNK), "\(child.name)")
            #expect(!metadata.isPackage)
            #expect(child.deviceID == UInt64(status.st_dev))
            if metadata.isDirectory {
                #expect(metadata.allocatedSize == 0 && metadata.logicalSize == 0)
                #expect(metadata.linkCount == 1)
                #expect(metadata.fileIdentity == .fileSystem(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)))
            } else {
                #expect(metadata.logicalSize == Int64(status.st_size), "\(child.name)")
                #expect(metadata.allocatedSize == Int64(status.st_blocks) * 512, "\(child.name)")
                #expect(metadata.linkCount == UInt64(max(status.st_nlink, 1)), "\(child.name)")
            }
        }
        #expect(compared > 10)
    }

    @Test func onlyDotNamesAreHiddenAndDotEntriesAreSkipped() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appending(path: ".dotfile"))
        try Data("b".utf8).write(to: root.appending(path: "visible"))
        try FileManager.default.createDirectory(at: root.appending(path: ".config"), withIntermediateDirectories: false)

        let children = try readChildren(of: root)
        #expect(Set(children.keys) == [".dotfile", "visible", ".config"])
        #expect(children[".dotfile"]?.isHidden == true)
        #expect(children[".config"]?.isHidden == true)
        #expect(children["visible"]?.isHidden == false)
    }

    @Test func hardLinksShareIdentityAndCarryTheirLinkCount() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "original")
        try Data(repeating: 7, count: 10_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appending(path: "link"))

        let children = try readChildren(of: root)
        let first = try #require(children["original"]?.metadata)
        let second = try #require(children["link"]?.metadata)
        #expect(first.linkCount == 2 && second.linkCount == 2)
        #expect(first.fileIdentity != nil)
        #expect(first.fileIdentity == second.fileIdentity)
    }

    @Test func metadataLoaderAgreesWithTheBulkReader() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 70_000).write(to: root.appending(path: "blob"))
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "blob")

        let loader = ScanMetadataLoader()
        for (name, bulk) in try readChildren(of: root) {
            let bulkMetadata = try #require(bulk.metadata)
            let loaded = try loader.metadata(for: root.appending(path: name))
            #expect(loaded.isDirectory == bulkMetadata.isDirectory, "\(name)")
            #expect(loaded.isSymbolicLink == bulkMetadata.isSymbolicLink, "\(name)")
            #expect(loaded.allocatedSize == bulkMetadata.allocatedSize, "\(name)")
            #expect(loaded.logicalSize == bulkMetadata.logicalSize, "\(name)")
            #expect(loaded.linkCount == bulkMetadata.linkCount, "\(name)")
            #expect(loaded.fileIdentity == bulkMetadata.fileIdentity, "\(name)")
        }
    }

    @Test func missingItemsThrowPOSIXErrors() {
        let loader = ScanMetadataLoader()
        #expect(throws: (any Error).self) {
            try loader.metadata(for: URL(filePath: "/nonexistent-\(UUID().uuidString)"))
        }
    }

    @Test func mountTableParsesOptionalFieldsAndEscapes() throws {
        let text = """
        22 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw,errors=remount-ro
        25 22 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:12 - proc proc rw
        61 22 0:51 / /mnt/My\\040Drive rw,relatime shared:30 master:4 - fuseblk /dev/sdb1 rw,user_id=0
        70 22 0:60 / /home/me/remote rw,nosuid,nodev,relatime shared:40 - fuse.sshfs me@host:/ rw
        garbage line
        """
        let mounts = LinuxMountTable.parse(text)
        #expect(mounts.count == 4)
        let usb = try #require(mounts.first { $0.fileSystemType == "fuseblk" })
        #expect(usb.mountPoint == "/mnt/My Drive")
        #expect(usb.source == "/dev/sdb1")
        #expect(usb.fileSystemClass == .foreign)
        #expect(mounts[0].deviceMajor == 259 && mounts[0].deviceMinor == 2)
        #expect(mounts[0].fileSystemClass == .local)
        #expect(mounts[1].fileSystemClass == .virtual)
        #expect(mounts[3].fileSystemClass == .network)

        #expect(LinuxMountTable.mount(containing: "/mnt/My Drive/photos", in: mounts)?.mountID == 61)
        #expect(LinuxMountTable.mount(containing: "/proc", in: mounts)?.mountID == 25)
        #expect(LinuxMountTable.mount(containing: "/procfs", in: mounts)?.mountID == 22)
        #expect(LinuxMountTable.mount(containing: "/home/me", in: mounts)?.mountID == 22)
    }

    @Test func mountDeviceIDMatchesStat() throws {
        var status = stat()
        #expect(stat("/", &status) == 0)
        let mounts = LinuxMountTable.current()
        let root = try #require(LinuxMountTable.mount(containing: "/", in: mounts))
        #expect(root.deviceID == UInt64(status.st_dev))
    }

    @Test func volumeCapacityFollowsDf() throws {
        // Other tests write files in parallel, so usage can move between two
        // reads: bracket the load with statvfs on both sides.
        func usedBytes() -> Int64 {
            var stats = statvfs()
            #expect(statvfs("/", &stats) == 0)
            return Int64(stats.f_blocks - stats.f_bfree) * Int64(stats.f_frsize)
        }
        let usedBefore = usedBytes()
        let info = try #require(VolumeSpaceInfo.load(for: URL(filePath: "/")))
        let usedAfter = usedBytes()
        #expect(min(usedBefore, usedAfter) <= info.usedBytes)
        #expect(info.usedBytes <= max(usedBefore, usedAfter))
        #expect(info.purgeableBytes == 0)
        #expect(info.totalCapacity == info.usedBytes + info.availableCapacity)
    }

    @Test func zeroBytesStillReadsAsBytes() {
        #expect(NeodiskFormatters.size(0) == "Zero bytes")
    }
}
#endif
