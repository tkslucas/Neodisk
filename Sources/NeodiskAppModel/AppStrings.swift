//
//  AppStrings.swift
//  Neodisk
//
//  Localized strings the shared model produces itself (synthetic node names,
//  relative-time pins). Apple platforms look them up with NSLocalizedString
//  in the app bundle's catalogs; a shell whose catalogs live elsewhere (the
//  GTK app reads Localization/*.lproj from its data directory) installs its
//  own lookup once at launch.
//

import Foundation

package enum AppStrings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lookup: (@Sendable (String) -> String)?

    package static func install(_ lookup: @escaping @Sendable (_ key: String) -> String) {
        lock.lock()
        defer { lock.unlock() }
        self.lookup = lookup
    }

    /// The localized form of the English source string `key`.
    package nonisolated static func localized(_ key: String, comment: String) -> String {
        lock.lock()
        let lookup = lookup
        lock.unlock()
        return lookup?(key) ?? NSLocalizedString(key, comment: comment)
    }

    /// A count's phrase in its singular (`one`, for exactly 1) or plural form,
    /// e.g. "%@ file" / "%@ files"; `arguments` fill the chosen format.
    package nonisolated static func plural(
        _ count: Int, one: String, other: String, _ arguments: CVarArg...
    ) -> String {
        String(format: localized(count == 1 ? one : other, comment: ""), arguments: arguments)
    }
}
