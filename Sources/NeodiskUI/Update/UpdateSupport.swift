// Sparkle gating: `swift run` builds have no bundle identifier and an unconfigured feed has nowhere to check.
// Pure functions so the gate is unit-testable.

import Foundation

enum UpdateSupport {
    /// Info.plist key for the Sparkle appcast feed URL.
    static let feedURLKey = "SUFeedURL"

    /// Anything but a bundle ID and a valid http(s) feed means "run without updates", never crash or nag.
    static func isSupported(bundleIdentifier: String?, feedURLString: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        guard let feedURLString else { return false }
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host() != nil else {
            return false
        }
        return true
    }

    /// The gate evaluated against the running process's main bundle.
    static func isSupported(in bundle: Bundle = .main) -> Bool {
        isSupported(
            bundleIdentifier: bundle.bundleIdentifier,
            feedURLString: bundle.object(forInfoDictionaryKey: feedURLKey) as? String
        )
    }
}
