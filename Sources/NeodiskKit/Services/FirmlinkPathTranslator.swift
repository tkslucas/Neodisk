// Firmlinks graft Data-volume subtrees into `/`, so `/Users/x` lives at `Users/x` on `/System/Volumes/Data`,
// which is how FSEvents reports it. `/usr/share/firmlinks` is the authoritative mapping.

import Foundation

struct FirmlinkPathTranslator: Sendable {
    /// Firmlink translation applies only to this volume; others are plain `mountPoint + relative`.
    static let dataVolumeMountPoint = "/System/Volumes/Data"

    /// Longest firmlink first so a nested entry (`/System/Library/Caches`) wins over a shorter prefix.
    private let entries: [(firmlink: String, dataRelative: String)]

    init(table: [String: String]) {
        entries = table
            .map { (firmlink: $0.key, dataRelative: $0.value) }
            .sorted { $0.firmlink.count > $1.firmlink.count }
    }

    /// Firmlink prefixes apply only on the Data volume. The result lands in the same `/private` namespace
    /// as `targetPath`'s tree.
    func absolutePath(
        forEventRelativePath relativePath: String,
        mountPoint: String,
        targetPath: String
    ) -> String {
        if mountPoint == Self.dataVolumeMountPoint {
            for entry in entries {
                if relativePath == entry.dataRelative {
                    return Self.namespaced(entry.firmlink, forTarget: targetPath)
                }
                if relativePath.hasPrefix(entry.dataRelative + "/") {
                    return Self.namespaced(
                        entry.firmlink + relativePath.dropFirst(entry.dataRelative.count),
                        forTarget: targetPath
                    )
                }
            }
        }
        if relativePath.isEmpty {
            return mountPoint
        }
        if mountPoint == "/" {
            return Self.namespaced("/" + relativePath, forTarget: targetPath)
        }
        return Self.namespaced(mountPoint + "/" + relativePath, forTarget: targetPath)
    }

    /// Self-gating: firmlink keys are absolute root paths that never prefix a plain volume's target.
    /// A target at the volume root maps to "".
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

    /// URL standardization strips `/private` from `/var|tmp|etc`, so those targets' trees store the stripped
    /// form while a `/` scan stores the qualified one; events must match the target's own namespace.
    private static func namespaced(_ path: String, forTarget targetPath: String) -> String {
        privateQualified(targetPath) == targetPath ? path : standardizedPrivatePrefix(path)
    }

    private static let privateStandardizedRoots = ["/private/var", "/private/tmp", "/private/etc"]

    static func standardizedPrivatePrefix(_ path: String) -> String {
        for root in privateStandardizedRoots {
            if path == root || path.hasPrefix(root + "/") {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }

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
    /// A missing table yields an empty translator, so paths pass through as `mountPoint + relative`.
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
