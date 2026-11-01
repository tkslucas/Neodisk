// The Localization/<lang>.lproj/Localizable.strings catalogs for shells that read them from disk rather than
// from a bundle (keys are the English source strings). The Windows app uses it; the GTK app's copy can move here.

import Foundation

package enum StringsCatalog {
    /// Catalog languages shipped in Localization/.
    package static let available = ["en", "de", "es", "fr", "it", "ja", "pt-BR", "zh-Hans"]

    /// The catalog for the first of `languages` that has one; empty for English (the keys are the strings).
    package static func load(from directory: URL, languages: [String]) -> [String: String] {
        for language in languages where language != "en" {
            let file = directory.appending(path: "\(language).lproj/Localizable.strings")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                return parse(text)
            }
        }
        return [:]
    }

    /// Catalog names for BCP 47 tags, most preferred first: "pt-PT" → pt-BR, "zh-Hans-CN" or "zh-CN" → zh-Hans,
    /// "de-AT" → de. Windows' preferred UI languages come in this form.
    package static func languages(forTags tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let language = parts.first?.lowercased(), !language.isEmpty else { continue }
            let rest = parts.dropFirst().map { $0.lowercased() }
            var matches: [String] = []
            switch language {
            case "zh" where rest.contains("hant") || rest.contains("tw") || rest.contains("hk"):
                continue
            case "zh":
                matches.append("zh-Hans")
            case "pt":
                matches.append("pt-BR")
            default:
                if let region = rest.first(where: { $0.count == 2 }) { matches.append("\(language)-\(region.uppercased())") }
                matches.append(language)
            }
            for match in matches where available.contains(match) && !result.contains(match) {
                result.append(match)
            }
        }
        return result
    }

    /// Parses the `"key" = "value";` .strings format (comments, escapes).
    package static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func skipTrivia() {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar == "\u{FEFF}" {
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
