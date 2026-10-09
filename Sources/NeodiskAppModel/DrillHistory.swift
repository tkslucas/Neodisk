//
//  DrillHistory.swift
//  NeodiskAppModel
//
//  Browser-style back/forward over the drill root (never the selection).
//  Entries are node IDs, so they outlive a rescan; vanished ones are skipped.
//

import Foundation

package struct DrillHistory: Sendable, Equatable {
    /// The oldest roots drop past this, so a long session can't grow it
    /// without bound.
    package static let limit = 100

    private var backStack: [String] = []
    private var forwardStack: [String] = []

    package init() {}

    package var canGoBack: Bool { !backStack.isEmpty }
    package var canGoForward: Bool { !forwardStack.isEmpty }

    /// A drill moved the map off `rootID`: it becomes the Back target, and
    /// the forward trail is gone, as a browser drops it on a new page.
    package mutating func recordLeaving(_ rootID: String) {
        backStack.append(rootID)
        if backStack.count > Self.limit {
            backStack.removeFirst(backStack.count - Self.limit)
        }
        forwardStack.removeAll()
    }

    /// The newest earlier root that `isValid` accepts, with `current` saved
    /// for Forward; nil when none is left.
    package mutating func goBack(from current: String, isValid: (String) -> Bool) -> String? {
        Self.step(from: current, popping: &backStack, pushing: &forwardStack, isValid: isValid)
    }

    /// The mirror of `goBack`.
    package mutating func goForward(from current: String, isValid: (String) -> Bool) -> String? {
        Self.step(from: current, popping: &forwardStack, pushing: &backStack, isValid: isValid)
    }

    private static func step(
        from current: String,
        popping source: inout [String],
        pushing destination: inout [String],
        isValid: (String) -> Bool
    ) -> String? {
        while let candidate = source.popLast() {
            guard candidate != current, isValid(candidate) else { continue }
            destination.append(current)
            return candidate
        }
        return nil
    }
}
