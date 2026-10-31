import Foundation

/// Why an item can't go to the Trash. Checked when it's collected and again right before the move.
public enum TrashRefusal: Sendable, Equatable {
    /// Not a real file: free space, hidden space, a "smaller items" group.
    case notAFile
    /// The folder or volume the scan is showing.
    case scanRoot
    /// A system folder, a volume, the home folder or one of its standard folders, or a folder holding one.
    case protectedLocation
    /// Already in a Trash; emptying it is the Trash's job.
    case alreadyInTrash
}

/// The locations Neodisk never moves to the Trash. Only these exact folders and the folders that hold them are
/// protected: what's inside them (a cache in ~/Library, an app in /Applications) can go.
public struct TrashSafetyPolicy: Sendable {
    /// Standardized paths, compared case-insensitively: APFS is case-insensitive by default, so `/applications`
    /// is `/Applications`. On a case-sensitive volume that only refuses a few more look-alike folders.
    private let protectedPaths: Set<String>
    /// The protected folders' device and inode, so a path spelled another way (a firmlink twin, a symlink) is
    /// still recognized.
    private let protectedIdentities: Set<FileIdentity>

    public init(protectedPaths: [String], protectedIdentities: Set<FileIdentity> = []) {
        var paths = Set<String>()
        for path in protectedPaths where !path.isEmpty {
            paths.insert(Self.key(path))
        }
        self.protectedPaths = paths
        self.protectedIdentities = protectedIdentities
    }

    /// The live policy: the static system list, the user's home and its standard folders, every mounted
    /// volume, firmlinks, and the running app. Reads the filesystem, so build it off the hot path and reuse it.
    public static func live(
        homeDirectory: String = NSHomeDirectory(),
        appBundlePath: String? = Bundle.main.bundlePath
    ) -> TrashSafetyPolicy {
        var paths = systemPaths
        paths.append(homeDirectory)
        paths += homeFolderNames.map { (homeDirectory as NSString).appendingPathComponent($0) }
        paths += mountedVolumePaths()
        #if os(macOS)
        // Firmlinked folders also live at their Data-volume path.
        let firmlinked = firmlinkPaths()
        paths += firmlinked
        paths += firmlinked.map { "/System/Volumes/Data" + $0 }
        paths.append("/System/Volumes/Data" + homeDirectory)
        // Every account's home folder.
        paths += childPaths(of: "/Users")
        #else
        paths += childPaths(of: "/home")
        #endif
        if let appBundlePath, appBundlePath.hasSuffix(".app") {
            paths.append(appBundlePath)
        }
        // Symlinked spellings (/tmp, /var and /etc on macOS) resolve to their targets.
        paths += paths.compactMap(realPath)

        var identities = Set<FileIdentity>()
        for path in Set(paths) {
            if case .found(let file) = CurrentFileState.read(atPath: path) {
                identities.insert(file.identity)
            }
        }
        return TrashSafetyPolicy(protectedPaths: paths, protectedIdentities: identities)
    }

    /// Nil when the node may go to the Trash. `scanRootID` is the root of the scan on screen.
    public func refusal(for node: FileNodeRecord, scanRootID: String) -> TrashRefusal? {
        if node.isSynthetic { return .notAFile }
        if node.id == scanRootID { return .scanRoot }
        return refusal(forPath: node.path, identity: node.isDirectory ? node.fileIdentity : nil)
    }

    /// The path-only part of `refusal(for:scanRootID:)`, also run right before each move.
    public func refusal(forPath rawPath: String, identity: FileIdentity?) -> TrashRefusal? {
        let path = Self.standardized(rawPath)
        if Self.isInsideTrash(path) { return .alreadyInTrash }
        let key = Self.key(path)
        if protectedPaths.contains(key) { return .protectedLocation }
        if let identity, protectedIdentities.contains(identity) { return .protectedLocation }
        // A folder that holds a protected location takes it along.
        let prefix = key == "/" ? "/" : key + "/"
        if protectedPaths.contains(where: { $0.hasPrefix(prefix) }) { return .protectedLocation }
        return nil
    }

    // MARK: - Lists

    #if os(macOS)
    static let systemPaths = [
        "/", "/Applications", "/Library", "/System", "/System/Volumes", "/System/Volumes/Data",
        "/Users", "/Users/Shared", "/Volumes", "/bin", "/cores", "/dev", "/etc", "/opt", "/private",
        "/private/etc", "/private/tmp", "/private/var", "/sbin", "/tmp", "/usr", "/usr/local", "/var",
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
    ]
    static let homeFolderNames = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Library/Application Support", "Library/Caches", "Library/CloudStorage", "Library/Containers",
        "Library/Group Containers", "Library/Mobile Documents", "Library/Preferences",
    ]
    #else
    static let systemPaths = [
        "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib32", "/lib64", "/libx32", "/media", "/mnt",
        "/opt", "/proc", "/root", "/run", "/sbin", "/snap", "/srv", "/sys", "/tmp", "/usr", "/usr/local", "/var",
    ]
    static let homeFolderNames = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Public", "Templates", "Videos",
        ".cache", ".config", ".local", ".local/share",
    ]
    #endif

    static func isInsideTrash(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            if component == ".Trash" || component == ".Trashes" || component.hasPrefix(".Trash-") {
                return true
            }
            if component == "Trash", index >= 2,
               components[index - 1] == "share", components[index - 2] == ".local" {
                return true
            }
        }
        return false
    }

    private static func mountedVolumePaths() -> [String] {
        #if os(Linux)
        return LinuxMountTable.current().map(\.mountPoint)
        #else
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return urls.map(\.path)
        #endif
    }

    #if os(macOS)
    /// `/usr/share/firmlinks` lists the folders the read-only system volume links to the Data volume.
    private static func firmlinkPaths() -> [String] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            return ["/Applications", "/Library", "/Users", "/Volumes", "/cores", "/opt", "/private", "/usr/local"]
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let visible = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            return visible.flatMap { $0.hasPrefix("/") ? $0 : nil }
        }
    }
    #endif

    private static func childPaths(of directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.map { (directory as NSString).appendingPathComponent($0) }
    }

    // MARK: - Paths

    /// Lexical only: `NSString.standardizingPath` would consult the disk and drop `/private`.
    static func standardized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func key(_ path: String) -> String {
        standardized(path).lowercased()
    }
}
