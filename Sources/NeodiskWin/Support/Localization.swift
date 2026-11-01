// UI strings from the shared Localization/<lang>.lproj catalogs (keys are the English source strings).

import Foundation

enum Strings {
    /// Filled once at launch, before any window exists.
    nonisolated(unsafe) static var table: [String: String] = [:]
}

/// The localized form of an English UI string.
func L(_ key: String) -> String {
    Strings.table[key] ?? key
}

/// A localized format string filled with `arguments` (`%@`, `%lld`, …).
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
