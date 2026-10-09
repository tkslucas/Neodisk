//
//  DataDirectory.swift
//  NeodiskGTK
//
//  Where the app's read-only data lives: the translation catalogs and its
//  own symbolic icons. An installed build keeps them in
//  <prefix>/share/neodisk next to <prefix>/bin/neodisk; `swift run` from a
//  checkout reads them straight from the repository.
//

import Foundation
import NeodiskKit

enum DataDirectory {
    enum Resource {
        /// Localization/<lang>.lproj string catalogs, shared with macOS.
        case localization
        /// An icon-theme directory (hicolor/scalable/actions/*.svg).
        case icons

        var installedName: String {
            switch self {
            case .localization: return "Localization"
            case .icons: return "icons"
            }
        }

        var repositoryPath: String {
            switch self {
            case .localization: return "Localization"
            case .icons: return "Packaging/linux/icons"
            }
        }
    }

    /// The first existing directory for `resource`.
    static func url(for resource: Resource) -> URL? {
        candidates(for: resource).first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func candidates(for resource: Resource) -> [URL] {
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NEODISK_DATA_DIR"], !override.isEmpty {
            roots.append(URL(filePath: override, directoryHint: .isDirectory))
        }
        let executable = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        roots.append(
            executable.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "share/\(AppChannel.current.slug)", directoryHint: .isDirectory)
        )
        var candidates = roots.map { $0.appending(path: resource.installedName, directoryHint: .isDirectory) }
        // Sources/NeodiskGTK/App/DataDirectory.swift → repository root.
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repository.appending(path: resource.repositoryPath, directoryHint: .isDirectory))
        return candidates
    }
}
