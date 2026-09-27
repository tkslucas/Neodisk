//
//  Locations.swift
//  NeodiskGTK
//
//  What the sidebar offers to scan: Home, the root filesystem, and the other
//  mounted volumes a person would recognize — disks, USB drives, network
//  shares — read from the mount table. Kernel interfaces (proc, sysfs,
//  cgroups), snap squashfs images, container layers, and boot partitions
//  stay out, the way GNOME Files' sidebar leaves them out.
//

import Foundation
import NeodiskKit

struct Location: Equatable, Identifiable {
    enum Kind: Equatable {
        case home
        case root
        case volume(removable: Bool, network: Bool)
        case folder
    }

    let id: String
    let title: String
    let subtitle: String?
    let kind: Kind
    let space: VolumeSpaceInfo?

    var path: String { id }

    var target: ScanTarget {
        switch kind {
        case .home, .folder:
            return ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: .folder)
        case .root, .volume:
            return ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory), kind: .volume)
        }
    }

    var iconName: String {
        switch kind {
        case .home: return "user-home-symbolic"
        case .root: return "drive-harddisk-system-symbolic"
        case .volume(let removable, let network):
            if network { return "folder-remote-symbolic" }
            return removable ? "drive-removable-media-symbolic" : "drive-harddisk-symbolic"
        case .folder: return "folder-symbolic"
        }
    }
}

enum Locations {
    /// Home, the root filesystem, then other volumes by mount point.
    static func current() -> [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var locations = [
            Location(id: home, title: L("Home"), subtitle: home, kind: .home, space: nil),
            Location(
                id: "/",
                title: L("Computer"),
                subtitle: "/",
                kind: .root,
                space: VolumeSpaceInfo.load(for: URL(filePath: "/"))
            ),
        ]
        var seenDevices: Set<UInt64> = []
        if let rootMount = LinuxMountTable.mount(containing: "/", in: LinuxMountTable.current()) {
            seenDevices.insert(rootMount.deviceID)
        }
        for mount in LinuxMountTable.current().sorted(by: { $0.mountPoint < $1.mountPoint })
        where isUserVisible(mount) && !seenDevices.contains(mount.deviceID) {
            seenDevices.insert(mount.deviceID)
            let url = URL(filePath: mount.mountPoint, directoryHint: .isDirectory)
            let isNetwork = mount.fileSystemClass == .network
            locations.append(Location(
                id: mount.mountPoint,
                title: volumeName(for: mount),
                subtitle: mount.mountPoint,
                kind: .volume(removable: isRemovable(mount), network: isNetwork),
                space: VolumeSpaceInfo.load(for: url)
            ))
        }
        return locations
    }

    /// Real filesystems at places people browse to.
    static func isUserVisible(_ mount: LinuxMount) -> Bool {
        switch mount.fileSystemClass {
        case .local, .foreign, .network: break
        case .memory, .virtual: return false
        }
        guard mount.mountPoint != "/" else { return false }
        // Bind mounts of a subdirectory show up again under their source.
        guard mount.root == "/" || mount.fileSystemType == "btrfs" else { return false }
        let hidden = ["/boot", "/efi", "/snap", "/var", "/usr", "/opt", "/srv", "/tmp", "/proc", "/sys", "/dev", "/run"]
        for prefix in hidden where mount.mountPoint == prefix || mount.mountPoint.hasPrefix(prefix + "/") {
            // Removable media mount under /run/media (udisks) — keep those.
            if mount.mountPoint.hasPrefix("/run/media/") { return true }
            return false
        }
        return true
    }

    private static func isRemovable(_ mount: LinuxMount) -> Bool {
        mount.mountPoint.hasPrefix("/media/") || mount.mountPoint.hasPrefix("/run/media/")
            || mount.fileSystemClass == .foreign
    }

    private static func volumeName(for mount: LinuxMount) -> String {
        let name = URL(filePath: mount.mountPoint).lastPathComponent
        return name.isEmpty ? mount.mountPoint : name
    }

    /// A recently scanned folder as a sidebar row.
    static func folder(_ path: String) -> Location {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let subtitle = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return Location(
            id: path,
            title: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
            subtitle: String(subtitle),
            kind: .folder,
            space: nil
        )
    }
}
