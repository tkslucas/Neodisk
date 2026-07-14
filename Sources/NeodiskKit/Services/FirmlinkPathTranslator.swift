//
//  FirmlinkPathTranslator.swift
//  Neodisk
//
//  Translates between the firmlinked path namespace the scan tree stores
//  (`/Users/...`, `/Applications/...`) and the Data-volume-relative paths an
//  FSEvents device-relative stream reports. On Catalina+ the Data volume
//  mounts at `/System/Volumes/Data`; firmlinks graft its subtrees into the
//  root namespace, so `/Users/x` physically lives at `Users/x` on the Data
//  volume. `/usr/share/firmlinks` is the authoritative mapping — left column
//  is the firmlink path in the root namespace, right column is the path
//  relative to the Data volume root.
//

import Foundation

struct FirmlinkPathTranslator: Sendable {
    /// Canonical Data volume mount point on Catalina+. Firmlink translation
    /// only applies to events on this volume; every other volume's paths are
    /// plain `mountPoint + relative`.
    static let dataVolumeMountPoint = "/System/Volumes/Data"

    /// firmlink root-namespace path → Data-volume-relative path, longest
    /// firmlink first so a nested entry (`/System/Library/Caches`) wins over
    /// any shorter prefix.
    private let entries: [(firmlink: String, dataRelative: String)]

    init(table: [String: String]) {
        entries = table
            .map { (firmlink: $0.key, dataRelative: $0.value) }
            .sorted { $0.firmlink.count > $1.firmlink.count }
    }

    /// An FSEvents relative path (relative to the device/volume root) mapped
    /// into the absolute path the scan tree uses. Firmlink prefixes are only
    /// honored on the Data volume; on any other volume the relative path is
    /// simply appended to its mount point. The result is `/private`-stripped
    /// to match Foundation's URL standardization (see below).
    func absolutePath(forEventRelativePath relativePath: String, mountPoint: String) -> String {
        if mountPoint == Self.dataVolumeMountPoint {
            for entry in entries {
                if relativePath == entry.dataRelative {
                    return Self.standardizedPrivatePrefix(entry.firmlink)
                }
                if relativePath.hasPrefix(entry.dataRelative + "/") {
                    return Self.standardizedPrivatePrefix(
                        entry.firmlink + relativePath.dropFirst(entry.dataRelative.count)
                    )
                }
            }
        }
        if relativePath.isEmpty {
            return mountPoint
        }
        if mountPoint == "/" {
            return Self.standardizedPrivatePrefix("/" + relativePath)
        }
        return Self.standardizedPrivatePrefix(mountPoint + "/" + relativePath)
    }

    /// A target's absolute path mapped to the path relative to the device's
    /// volume root, used as the FSEvents watch path. Firmlinked prefixes fold
    /// back to their Data-relative form; the match is self-gating because the
    /// firmlink keys are absolute root-namespace paths that never prefix a
    /// plain volume's target. A target at the volume root maps to "".
    func relativePath(forTarget targetPath: String, mountPoint: String) -> String {
        // `/var/...` targets arrive `/private`-stripped (Foundation URL
        // standardization); re-qualify so they match the `/private` firmlink.
        let targetPath = Self.privateQualified(targetPath)
        for entry in entries {
            if targetPath == entry.firmlink {
                return entry.dataRelative
            }
            if targetPath.hasPrefix(entry.firmlink + "/") {
                return entry.dataRelative + targetPath.dropFirst(entry.firmlink.count)
            }
        }
        if targetPath == mountPoint {
            return ""
        }
        let prefix = mountPoint == "/" ? "/" : mountPoint + "/"
        if targetPath.hasPrefix(prefix) {
            return String(targetPath.dropFirst(prefix.count))
        }
        return ""
    }

    /// Foundation's URL standardization drops the `/private` prefix from
    /// `/private/var|tmp|etc` paths (the root-level symlinks make both forms
    /// name the same directory), and `ScanTarget` normalization inherits
    /// that — so the scan tree stores the stripped form and event paths must
    /// surface the same way.
    private static let privateStandardizedRoots = ["/private/var", "/private/tmp", "/private/etc"]

    static func standardizedPrivatePrefix(_ path: String) -> String {
        for root in privateStandardizedRoots {
            if path == root || path.hasPrefix(root + "/") {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }

    /// The inverse of `standardizedPrivatePrefix`, for mapping a stripped
    /// target path back into the `/private` namespace the firmlink table
    /// (and the physical Data volume layout) uses.
    static func privateQualified(_ path: String) -> String {
        for root in ["/var", "/tmp", "/etc"] {
            if path == root || path.hasPrefix(root + "/") {
                return "/private" + path
            }
        }
        return path
    }
}

extension FirmlinkPathTranslator {
    /// The process-wide translator built from `/usr/share/firmlinks`, loaded
    /// once on first use. A missing or unreadable table yields an empty
    /// translator (paths pass through as `mountPoint + relative`).
    static let system = FirmlinkPathTranslator(table: loadSystemTable())

    private static func loadSystemTable() -> [String: String] {
        guard let contents = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            return [:]
        }
        var table: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count >= 2 else { continue }
            var dataRelative = String(columns[1])
            if dataRelative.hasPrefix("/") {
                dataRelative.removeFirst()
            }
            table[String(columns[0])] = dataRelative
        }
        return table
    }
}
