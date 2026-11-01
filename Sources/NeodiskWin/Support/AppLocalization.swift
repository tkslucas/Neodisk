// Which catalog to load: the user's preferred Windows UI languages, from the Localization folder next to the
// executable when installed, or the repository's under `swift run`.

import Foundation
import NeodiskAppModel
import WinSDK

enum AppLocalization {
    static func load() -> [String: String] {
        guard let directory = directory() else { return [:] }
        return StringsCatalog.load(from: directory, languages: StringsCatalog.languages(forTags: preferredTags()))
    }

    /// NEODISK_LANGUAGE overrides the system's choice, for checking a translation.
    static func preferredTags() -> [String] {
        if let forced = ProcessInfo.processInfo.environment["NEODISK_LANGUAGE"], !forced.isEmpty {
            return [forced]
        }
        var count: ULONG = 0
        var length: ULONG = 0
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &length), length > 0 else { return [] }
        var buffer = [WCHAR](repeating: 0, count: Int(length))
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, &buffer, &length) else { return [] }
        // A double-NUL-terminated list.
        return buffer.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
    }

    private static func directory() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NEODISK_DATA_DIR"], !override.isEmpty {
            candidates.append(URL(filePath: override, directoryHint: .isDirectory).appending(path: "Localization"))
        }
        let executable = URL(filePath: CommandLine.arguments[0])
        candidates.append(executable.deletingLastPathComponent().appending(path: "Localization", directoryHint: .isDirectory))
        // Sources/NeodiskWin/Support/AppLocalization.swift → the repository root.
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repository.appending(path: "Localization", directoryHint: .isDirectory))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
