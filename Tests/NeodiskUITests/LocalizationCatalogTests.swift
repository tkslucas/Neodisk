import Foundation
import Testing

struct LocalizationCatalogTests {
    @Test func catalogsHaveMatchingKeysAndFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization")
        let locales = ["en", "de", "es", "fr", "it", "ja", "pt-BR", "zh-Hans"]
        for name in ["Localizable", "InfoPlist"] {
            let reference = try catalog(root, locale: "en", name: name)
            for locale in locales {
                let strings = try catalog(root, locale: locale, name: name)
                #expect(Set(strings.keys) == Set(reference.keys), "\(locale)/\(name): missing or unexpected keys")
                for (key, value) in strings {
                    #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(locale): \(key)")
                    if let expected = reference[key] {
                        #expect(formatArguments(value) == formatArguments(expected), "\(locale): \(key) has mismatched format arguments")
                    }
                }
            }
        }
    }

    private func catalog(_ root: URL, locale: String, name: String) throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(locale).lproj/\(name).strings"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private func formatArguments(_ text: String) -> [String] {
        // Positional specifiers may reorder translated arguments. Compare each
        // argument's position and type, ignoring escaped percent characters.
        let pattern = #"%%|%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|h|l|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var position = 0
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard ns.substring(with: match.range) != "%%" else { return nil }
            position += 1
            let index = match.range(at: 1).location == NSNotFound ? String(position) : ns.substring(with: match.range(at: 1))
            let length = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            return index + ":" + length + ns.substring(with: match.range(at: 3))
        }.sorted()
    }
}
