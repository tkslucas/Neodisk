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
    /// A folder the scan couldn't look inside: what it holds, and how much, is unknown.
    case unreadableFolder
    /// A name the scan couldn't decode (not UTF-8 on Linux), so its path doesn't lead back to it.
    case undecodableName
    /// Inside a package (macOS): an app, plug-in or document Finder shows as one file, which breaks without it.
    case insidePackage
}

/// The locations Neodisk never moves to the Trash. Only these exact folders and the folders that hold them are
/// protected: what's inside them (a cache in ~/Library, an app in /Applications) can go.
public struct TrashSafetyPolicy: Sendable {
    /// Standardized paths, compared case-insensitively: APFS is case-insensitive by default, so `/applications`
    /// is `/Applications`. On a case-sensitive volume that only refuses a few more look-alike folders.
    private let protectedPaths: Set<String>
    /// Every folder above a protected path, so "holds a protected location" is one lookup.
    private let protectedHolders: Set<String>
    /// The protected folders' device and inode, so a path spelled another way (a firmlink twin, a symlink) is
    /// still recognized.
    private let protectedIdentities: Set<FileIdentity>

    public init(protectedPaths: [String], protectedIdentities: Set<FileIdentity> = []) {
        var paths = Set<String>()
        var holders = Set<String>()
        for path in protectedPaths where !path.isEmpty {
            let key = Self.key(path)
            paths.insert(key)
            var holder = key
            while let slash = holder.lastIndex(of: "/"), holder != "/" {
                holder = slash == holder.startIndex ? "/" : String(holder[..<slash])
                holders.insert(holder)
            }
        }
        self.protectedPaths = paths
        self.protectedHolders = holders
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
        // Each cloud provider's root (iCloud Drive, and every File Provider folder).
        let library = (homeDirectory as NSString).appendingPathComponent("Library")
        paths += childPaths(of: (library as NSString).appendingPathComponent("CloudStorage"))
        paths.append((library as NSString).appendingPathComponent("Mobile Documents/com~apple~CloudDocs"))
        // Firmlinked folders also live at their Data-volume path.
        let firmlinked = firmlinkPaths()
        paths += firmlinked
        paths += firmlinked.map { "/System/Volumes/Data" + $0 }
        paths.append("/System/Volumes/Data" + homeDirectory)
        // Every account's home folder, and every mount point and its alias.
        paths += childPaths(of: "/Users")
        paths += childPaths(of: "/Volumes")
        #else
        paths += childPaths(of: "/home")
        paths += xdgUserDirectories(homeDirectory: homeDirectory)
        // A data folder moved out of ~/.local/share, and the Trash inside it.
        if let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], dataHome.hasPrefix("/") {
            paths += [dataHome, (dataHome as NSString).appendingPathComponent("Trash")]
        }
        #endif
        // The system's own top-level folders, whatever they're called on this machine.
        for directory in systemFoldersWithProtectedChildren {
            paths += childPaths(of: directory)
        }
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

    /// Nil when the node may go to the Trash. `scanRootID` is the root of the scan on screen; `store`, when given,
    /// adds the packages the scan recognized above the node (Finder's bundle bit, not only known extensions).
    public func refusal(for node: FileNodeRecord, scanRootID: String, in store: FileTreeStore? = nil) -> TrashRefusal? {
        refusal(for: node, scanRootID: scanRootID, in: store, folder: Self.lookUpFolder)
    }

    /// `refusal(for:scanRootID:in:)` for a large selection: each folder is looked at once, not once per item.
    public func refusals(
        for nodes: [FileNodeRecord],
        scanRootID: String,
        in store: FileTreeStore? = nil
    ) -> [TrashRefusal?] {
        var folders: [String: FolderLookup] = [:]
        return nodes.map { node in
            refusal(for: node, scanRootID: scanRootID, in: store) { path in
                if let known = folders[path] { return known }
                let lookup = Self.lookUpFolder(path)
                folders[path] = lookup
                return lookup
            }
        }
    }

    private func refusal(
        for node: FileNodeRecord,
        scanRootID: String,
        in store: FileTreeStore?,
        folder: (String) -> FolderLookup
    ) -> TrashRefusal? {
        if node.isSynthetic { return .notAFile }
        if node.id == scanRootID { return .scanRoot }
        if node.path.contains("\u{FFFD}") { return .undecodableName }
        if node.isDirectory, !node.isSelfAccessible { return .unreadableFolder }
        let identity = node.isDirectory ? node.fileIdentity : nil
        if let refusal = refusal(forPath: node.path, identity: identity, folder: folder) {
            return refusal
        }
        var ancestor = store?.parent(of: node.id)
        while let holder = ancestor {
            if holder.isPackage { return .insidePackage }
            ancestor = store?.parent(of: holder.id)
        }
        return nil
    }

    /// The path-only part of `refusal(for:scanRootID:)`, also run right before each move.
    public func refusal(forPath rawPath: String, identity: FileIdentity?) -> TrashRefusal? {
        refusal(forPath: rawPath, identity: identity, folder: Self.lookUpFolder)
    }

    private func refusal(
        forPath rawPath: String,
        identity: FileIdentity?,
        folder lookUp: (String) -> FolderLookup
    ) -> TrashRefusal? {
        let path = Self.standardized(rawPath)
        guard path != "/", let slash = path.lastIndex(of: "/") else {
            return protectedRefusal(key: "/", identity: identity)
        }
        let name = String(path[path.index(after: slash)...])
        let folder = lookUp(slash == path.startIndex ? "/" : String(path[..<slash]))
        if let refusal = refusal(name: name, in: folder.spelled, identity: identity) { return refusal }
        // A scan reached through a symlink (/tmp, a linked folder) spells paths unlike the mount table: check the
        // item again under its folder's real path, or a folder holding a mounted volume would pass.
        return folder.real.flatMap { refusal(name: name, in: $0, identity: nil) }
    }

    private func refusal(name: String, in folder: Folder, identity: FileIdentity?) -> TrashRefusal? {
        if folder.isInsideTrash || Self.isTrashName(name[...], inLocalShare: folder.isLocalShare) {
            return .alreadyInTrash
        }
        if folder.isInsidePackage { return .insidePackage }
        let key = (folder.key == "/" ? "" : folder.key) + "/" + name.lowercased()
        return protectedRefusal(key: key, identity: identity)
    }

    private func protectedRefusal(key: String, identity: FileIdentity?) -> TrashRefusal? {
        if protectedPaths.contains(key) { return .protectedLocation }
        if let identity, protectedIdentities.contains(identity) { return .protectedLocation }
        // A folder that holds a protected location takes it along.
        if protectedHolders.contains(key) { return .protectedLocation }
        return nil
    }

    // MARK: - Folders

    /// What the checks know about the folder holding an item, the same for all its items.
    struct Folder {
        /// Standardized and lowercased.
        let key: String
        /// The folder is a Trash or inside one.
        let isInsideTrash: Bool
        /// The folder is a package or inside one: what's inside goes with the whole package or not at all.
        let isInsidePackage: Bool
        /// `~/.local/share`, where `Trash` is the Trash.
        let isLocalShare: Bool

        init(standardizedPath path: String) {
            let components = path.split(separator: "/")
            var isInsideTrash = false
            var isInsidePackage = false
            for (index, component) in components.enumerated() {
                let inLocalShare = index >= 2 && components[index - 1] == "share" && components[index - 2] == ".local"
                isInsideTrash = isInsideTrash || TrashSafetyPolicy.isTrashName(component, inLocalShare: inLocalShare)
                isInsidePackage = isInsidePackage || TrashSafetyPolicy.isPackageName(component)
            }
            let count = components.count
            key = path.lowercased()
            self.isInsideTrash = isInsideTrash
            self.isInsidePackage = isInsidePackage
            isLocalShare = count >= 2 && components[count - 1] == "share" && components[count - 2] == ".local"
        }
    }

    /// The folder as spelled, and under its real path when a symlink makes that differ.
    typealias FolderLookup = (spelled: Folder, real: Folder?)

    static func lookUpFolder(_ path: String) -> FolderLookup {
        let real = realPath(path).map(standardized).flatMap { $0 == path ? nil : Folder(standardizedPath: $0) }
        return (Folder(standardizedPath: path), real)
    }

    // MARK: - Lists

    #if os(macOS)
    static let systemPaths = [
        "/", "/Applications", "/Library", "/System", "/System/Volumes", "/System/Volumes/Data",
        "/Users", "/Users/Shared", "/Volumes", "/bin", "/cores", "/dev", "/etc", "/opt", "/private",
        "/private/etc", "/private/tmp", "/private/var", "/sbin", "/tmp", "/usr", "/usr/local", "/var",
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
    ]
    static let systemFoldersWithProtectedChildren = ["/", "/System", "/private", "/private/var", "/usr"]
    static let homeFolderNames = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Library/Application Support", "Library/Caches", "Library/CloudStorage", "Library/Containers",
        "Library/Group Containers", "Library/Keychains", "Library/Mobile Documents", "Library/Preferences",
        ".ssh", ".gnupg",
    ]
    #else
    static let systemPaths = [
        "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib32", "/lib64", "/libx32", "/media", "/mnt",
        "/opt", "/proc", "/root", "/run", "/sbin", "/snap", "/srv", "/sys", "/tmp", "/usr", "/usr/local", "/var",
    ]
    static let systemFoldersWithProtectedChildren = ["/", "/usr", "/var"]
    static let homeFolderNames = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Public", "Templates", "Videos",
        ".cache", ".config", ".local", ".local/share", ".local/share/keyrings", ".ssh", ".gnupg",
    ]
    #endif

    /// The user's own folder names (`~/Bilder`, `~/Documentos`), from `~/.config/user-dirs.dirs`.
    static func xdgUserDirectories(homeDirectory: String, contents: String? = nil) -> [String] {
        let file = (homeDirectory as NSString).appendingPathComponent(".config/user-dirs.dirs")
        guard let text = contents ?? (try? String(contentsOfFile: file, encoding: .utf8)) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("XDG_"), let equals = trimmed.firstIndex(of: "=") else { return nil }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("$HOME") {
                value = homeDirectory + value.dropFirst("$HOME".count)
            }
            return value.hasPrefix("/") ? value : nil
        }
    }

    static func isTrashName(_ component: Substring, inLocalShare: Bool) -> Bool {
        component == ".Trash" || component == ".Trashes" || component.hasPrefix(".Trash-")
            || (component == "Trash" && inLocalShare)
    }

    /// Code bundles, refused even where the system doesn't register their extension as a package.
    static let codeBundleExtensions: Set<String> = [
        "app", "appex", "bundle", "component", "framework", "kext", "plugin", "systemextension", "xpc",
    ]

    /// A folder name the system calls a package (the scanner's verdict by extension), or a code bundle's.
    static func isPackageName(_ component: Substring) -> Bool {
        #if os(macOS)
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return false }
        return codeBundleExtensions.contains(component[component.index(after: dot)...].lowercased())
            || PackageExtensionCatalog.shared.isPackageName(String(component))
        #else
        return false
        #endif
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
