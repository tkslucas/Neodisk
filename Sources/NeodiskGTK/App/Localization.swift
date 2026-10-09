//
//  Localization.swift
//  NeodiskGTK
//
//  The Linux app reads the same Localization/<lang>.lproj/Localizable.strings
//  catalogs the macOS app bundles — keys are the English source strings, so
//  a string already translated for the Mac is translated here too. The
//  language comes from the POSIX locale environment (LANGUAGE, LC_ALL,
//  LC_MESSAGES, LANG), like any GTK app.
//

import Foundation

enum Localization {
    /// Catalog languages shipped in Localization/.
    static let available = ["en", "de", "es", "fr", "it", "ja", "pt-BR", "zh-Hans"]

    static let strings: [String: String] = loadCatalog()

    /// Catalog names for the user's locale, most preferred first:
    /// "pt_BR.UTF-8" → pt-BR, "zh_CN" → zh-Hans, "de_AT" → de.
    static func preferredLanguages(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var candidates: [String] = []
        if let language = environment["LANGUAGE"], !language.isEmpty {
            candidates += language.split(separator: ":").map(String.init)
        }
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = environment[key], !value.isEmpty {
                candidates.append(value)
                break
            }
        }
        var result: [String] = []
        for candidate in candidates {
            let locale = candidate
                .split(separator: ".").first.map(String.init) ?? candidate
            let base = locale.split(separator: "@").first.map(String.init) ?? locale
            guard base != "C", base != "POSIX" else { continue }
            let parts = base.split(separator: "_").map(String.init)
            guard let languageCode = parts.first?.lowercased() else { continue }
            let region = parts.count > 1 ? parts[1].uppercased() : nil
            var matches: [String] = []
            switch (languageCode, region) {
            case ("zh", "CN"), ("zh", "SG"), ("zh", nil):
                matches.append("zh-Hans")
            case ("pt", _):
                matches.append("pt-BR")
            default:
                if let region { matches.append("\(languageCode)-\(region)") }
                matches.append(languageCode)
            }
            for match in matches where available.contains(match) && !result.contains(match) {
                result.append(match)
            }
        }
        return result
    }

    private static func loadCatalog() -> [String: String] {
        guard let directory = DataDirectory.url(for: .localization) else { return [:] }
        for language in preferredLanguages() where language != "en" {
            let file = directory.appending(path: "\(language).lproj/Localizable.strings")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                return parseStrings(text)
            }
        }
        return [:]
    }

    /// Parses the `"key" = "value";` .strings format (comments, escapes).
    static func parseStrings(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func skipTrivia() {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                    index += 1
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                    index += 2
                    while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                        index += 1
                    }
                    index += 2
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }

        func quoted() -> String? {
            guard index < scalars.count, scalars[index] == "\"" else { return nil }
            index += 1
            var value = String.UnicodeScalarView()
            while index < scalars.count, scalars[index] != "\"" {
                if scalars[index] == "\\", index + 1 < scalars.count {
                    index += 1
                    switch scalars[index] {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "r": value.append("\r")
                    default: value.append(scalars[index])
                    }
                } else {
                    value.append(scalars[index])
                }
                index += 1
            }
            index += 1
            return String(value)
        }

        while index < scalars.count {
            skipTrivia()
            guard let key = quoted() else { break }
            skipTrivia()
            guard index < scalars.count, scalars[index] == "=" else { break }
            index += 1
            skipTrivia()
            guard let value = quoted() else { break }
            skipTrivia()
            if index < scalars.count, scalars[index] == ";" { index += 1 }
            result[key] = value
        }
        return result
    }
}

/// The localized form of an English UI string.
func L(_ key: String) -> String {
    Localization.strings[key] ?? key
}

/// A localized format string filled with `arguments` (`%@`, `%lld`, …).
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
