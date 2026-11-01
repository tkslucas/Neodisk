// The Windows locations Neodisk never moves to the Recycle Bin, with the same intent as the macOS and Linux
// lists: the system's own folders, every drive, each account's profile and its standard folders.

#if os(Windows)
import Foundation

extension TrashSafetyPolicy {
    /// Every drive root and the system-wide folders, wherever this machine keeps them.
    static func windowsSystemPaths() -> [String] {
        var paths: [String] = []
        for root in WindowsVolume.logicalDriveRoots() {
            paths.append(root)
            paths += ["$Recycle.Bin", "System Volume Information", "Recovery", "Boot", "EFI"]
                .map { (root as NSString).appendingPathComponent($0) }
        }
        for name in ["SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "PUBLIC"] {
            if let value = windowsEnvironment(name) { paths.append(value) }
        }
        if let systemRoot = windowsEnvironment("SystemRoot") {
            paths += ["System32", "SysWOW64", "WinSxS", "Fonts", "Temp"]
                .map { (systemRoot as NSString).appendingPathComponent($0) }
        }
        paths += windowsProfilesFolders()
        return paths
    }

    /// Folders whose every child is protected: the system drive's top level and the Windows folder.
    static func windowsFoldersWithProtectedChildren() -> [String] {
        [windowsEnvironment("SystemDrive").map { $0 + "\\" }, windowsEnvironment("SystemRoot")].compactMap { $0 }
    }

    /// Standard folders inside a profile, as on the other platforms.
    static let windowsHomeFolderNames = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos", "Favorites", "Links", "Contacts",
        "Saved Games", "Searches", "OneDrive", "AppData", "AppData/Local", "AppData/LocalLow", "AppData/Roaming",
        "AppData/Local/Temp", ".ssh",
    ]

    /// The folder holding the accounts' profiles (`C:\Users`), from this account's profile and the system drive.
    static func windowsProfilesFolders() -> [String] {
        var folders: [String] = []
        if let profile = windowsEnvironment("USERPROFILE") {
            folders.append((profile as NSString).deletingLastPathComponent)
        }
        if let drive = windowsEnvironment("SystemDrive") {
            folders.append(drive + "\\Users")
        }
        return folders
    }

    /// `$Recycle.Bin` (and `RECYCLER` on old drives), in any letter case.
    static func isWindowsRecycleBinName(_ component: Substring) -> Bool {
        let lowered = component.lowercased()
        return lowered == "$recycle.bin" || lowered == "recycler"
    }

    /// One spelling for every way to write a Windows path: `C:\Users\X`, `C:/Users/X` and `/C:/Users/X` all
    /// become `/C:/Users/X`, so `/` holds every drive and the checks need no drive logic. UNC paths keep their
    /// double slash (`//server/share/x`). `..` never climbs above a drive or share.
    static func windowsStandardized(_ path: String) -> String {
        let isUNC = path.hasPrefix("//") || path.hasPrefix("\\\\")
        var components: [Substring] = []
        for component in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            switch component {
            case ".": continue
            case "..": if components.count > (isUNC ? 2 : 1) { components.removeLast() }
            default: components.append(component)
            }
        }
        return (isUNC ? "//" : "/") + components.joined(separator: "/")
    }

    /// A path the system can open, from a standardized one or a raw one; nil for `/` and for paths that name
    /// no drive or share, so a lookup never goes to the network for them.
    static func windowsSystemSpelling(_ path: String) -> String? {
        if path.hasPrefix("//") || path.hasPrefix("\\\\") { return path }
        let trimmed = String(path.drop(while: { $0 == "/" }))
        if WindowsPath.isDriveAbsolute(trimmed) { return trimmed }
        if trimmed.utf16.count == 2, trimmed.hasSuffix(":") { return trimmed + "/" }
        return nil
    }

    /// Environment variable names are case-insensitive on Windows.
    static func windowsEnvironment(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let value = environment[name]
            ?? environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
#endif
