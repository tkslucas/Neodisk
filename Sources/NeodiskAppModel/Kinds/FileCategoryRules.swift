//
//  FileCategoryRules.swift
//  Neodisk
//
//  The user's changes to the Categories grouping — extensions moved to
//  another category, and categories of their own — and the rules both apps
//  classify with once those changes are merged over the built-in table.
//  Each app persists the customization as JSON and installs it here at
//  launch and on every change.
//

import Foundation
import NeodiskKit

/// A category the user made.
package struct CustomFileCategory: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package var name: String
}

/// What the user changed about the Categories grouping: the persisted form.
package struct FileCategoryCustomization: Codable, Equatable, Sendable {
    /// The user's own categories, in the order they were made (which also
    /// decides the colors they get).
    package var categories: [CustomFileCategory] = []
    /// Lowercased extension → category ID, only where it differs from the
    /// built-in table.
    package var extensions: [String: String] = [:]

    package init() {}

    package var isEmpty: Bool { categories.isEmpty && extensions.isEmpty }

    /// Puts an extension in a category; choosing its built-in category
    /// drops the override instead of storing one.
    package mutating func assign(extension ext: String, to categoryID: String) {
        let ext = ext.lowercased()
        if categoryID == FileCategoryRules.builtInCategoryID(forExtension: ext) {
            extensions.removeValue(forKey: ext)
        } else {
            extensions[ext] = categoryID
        }
    }

    /// Adds a category and returns its ID. Blank names are refused.
    @discardableResult
    package mutating func addCategory(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let id = FileCategoryRules.customIDPrefix + UUID().uuidString.prefix(8).lowercased()
        categories.append(CustomFileCategory(id: id, name: name))
        return id
    }

    package mutating func renameCategory(id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].name = name
    }

    /// Removes a category; its extensions go back to their built-in ones.
    package mutating func removeCategory(id: String) {
        categories.removeAll { $0.id == id }
        extensions = extensions.filter { $0.value != id }
    }

    // MARK: Persistence

    /// The JSON both apps store; "" for no changes.
    package var json: String {
        guard !isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes stored JSON. Unreadable or empty input is no changes, so a
    /// damaged setting falls back to the built-in table.
    package init(json: String) {
        self.init()
        guard !json.isEmpty,
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return }
        // Overrides naming a category that no longer exists are dropped.
        let known = Set(FileKindClassifier.categoryKindsByID.keys).union(decoded.categories.map(\.id))
        categories = decoded.categories
        extensions = decoded.extensions.filter { known.contains($0.value) }
    }
}

/// The category table in effect: the built-in one with the user's
/// customization merged over it. Immutable; `install` swaps in a new one.
package final class FileCategoryRules: Sendable {
    package let customization: FileCategoryCustomization
    /// Lowercased extension → category ID.
    package let categoryIDByExtension: [String: String]
    package let customKindsByID: [String: FileKind]
    /// Identifies these rules in persisted aggregates: kind stats computed
    /// under other rules don't describe the categories on screen.
    package let fingerprint: String

    /// Bumped whenever the built-in table changes what a file is filed
    /// under, so stats persisted under the old table are recomputed.
    package nonisolated static let builtInRevision = 2

    package nonisolated static let customIDPrefix = "cat-user-"

    package nonisolated static let builtIn = FileCategoryRules(FileCategoryCustomization())

    package nonisolated init(_ customization: FileCategoryCustomization) {
        self.customization = customization
        categoryIDByExtension = FileKindClassifier.builtInCategoryIDByExtension
            .merging(customization.extensions) { _, user in user }
        customKindsByID = Dictionary(
            customization.categories.map { ($0.id, FileKind(id: $0.id, displayName: $0.name)) },
            uniquingKeysWith: { first, _ in first }
        )
        let json = customization.json
        fingerprint = json.isEmpty
            ? "\(Self.builtInRevision)"
            : "\(Self.builtInRevision)-\(Self.fnv1a(json))"
    }

    /// The categories an extension can go in: built-in ones, then the
    /// user's.
    package var assignableCategories: [FileKind] {
        FileKindClassifier.assignableCategories
            + customization.categories.map { FileKind(id: $0.id, displayName: $0.name) }
    }

    package func categoryID(forExtension ext: String) -> String {
        categoryIDByExtension[ext.lowercased()] ?? FileKindClassifier.otherCategory.id
    }

    package func isOverridden(extension ext: String) -> Bool {
        customization.extensions[ext.lowercased()] != nil
    }

    /// Position of a user category among the user's categories — its
    /// color slot. nil for built-in and unknown IDs.
    package func customColorIndex(forID id: String) -> Int? {
        customization.categories.firstIndex { $0.id == id }
    }

    package nonisolated static func builtInCategoryID(forExtension ext: String) -> String {
        FileKindClassifier.builtInCategoryIDByExtension[ext.lowercased()]
            ?? FileKindClassifier.otherCategory.id
    }

    package nonisolated static func isCustomCategoryID(_ id: String) -> Bool {
        id.hasPrefix(customIDPrefix)
    }

    /// Whether a Types-grouping kind ID stands for an extension that can
    /// move to another category, rather than a pseudo-kind (no extension,
    /// aliases, system data, summarized folders).
    package nonisolated static func isAssignableTypeID(_ kindID: String) -> Bool {
        !["no-extension", "symlink", "system-data", "summarized", "folder"].contains(kindID)
    }

    // MARK: Installed rules

    private nonisolated static let lock = NSLock()
    nonisolated(unsafe) private static var installed = FileCategoryRules.builtIn

    /// The rules in effect. Loops over a whole tree read this once, so a
    /// change mid-build can't split one catalog across two tables.
    package nonisolated static var current: FileCategoryRules {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// Puts a customization in effect. Returns false when it already was —
    /// nothing to reclassify.
    @discardableResult
    package nonisolated static func install(_ customization: FileCategoryCustomization) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard installed.customization != customization else { return false }
        installed = FileCategoryRules(customization)
        return true
    }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    private nonisolated static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Path patterns ("/steamapps/") that file everything under a folder in
/// one category. Runs for every node in a catalog build, so matching walks
/// the path's slashes once with memchr and compares only where a pattern
/// could start, over raw buffers allocated once (array copies and their
/// reference counting per node cost more than the match itself).
package final class FolderCategoryRules: @unchecked Sendable {
    private let categoryIDs: [String]
    /// Every pattern's bytes, back to back.
    private let bytes: UnsafeMutablePointer<UInt8>
    private let starts: UnsafeMutablePointer<Int>
    private let lengths: UnsafeMutablePointer<Int>
    /// Per byte after a slash, a bit per pattern that starts with it.
    private let candidates: UnsafeMutablePointer<UInt32>

    package init(_ rules: [(pattern: String, categoryID: String)]) {
        precondition(rules.count <= 32, "candidate masks hold 32 patterns")
        let patterns = rules.map { Array($0.pattern.utf8) }
        categoryIDs = rules.map(\.categoryID)
        bytes = .allocate(capacity: patterns.reduce(0) { $0 + $1.count })
        starts = .allocate(capacity: patterns.count)
        lengths = .allocate(capacity: patterns.count)
        candidates = .allocate(capacity: 256)
        candidates.initialize(repeating: 0, count: 256)
        var offset = 0
        for (index, pattern) in patterns.enumerated() {
            precondition(pattern.count > 2 && pattern.first == 0x2F && pattern.last == 0x2F,
                         "folder patterns are /component(s)/")
            (bytes + offset).initialize(from: pattern, count: pattern.count)
            starts[index] = offset
            lengths[index] = pattern.count
            candidates[Int(pattern[1])] |= 1 << UInt32(index)
            offset += pattern.count
        }
    }

    deinit {
        bytes.deallocate()
        starts.deallocate()
        lengths.deallocate()
        candidates.deallocate()
    }

    /// The category of the outermost matching folder, if any.
    package func categoryID(forPath path: String) -> String? {
        var path = path
        return path.withUTF8 { categoryID(inPath: $0) }
    }

    package func categoryID(inPath buffer: UnsafeBufferPointer<UInt8>) -> String? {
        let match = { () -> Int? in
            guard let base = buffer.baseAddress else { return nil }
            let count = buffer.count
            var offset = 0
            while offset < count - 1,
                  let slash = memchr(base + offset, 0x2F, count - offset - 1) {
                let position = base.distance(to: slash.assumingMemoryBound(to: UInt8.self))
                var mask = candidates[Int(base[position + 1])]
                while mask != 0 {
                    let index = mask.trailingZeroBitCount
                    mask &= mask - 1
                    let length = lengths[index]
                    if position + length <= count,
                       memcmp(base + position, bytes + starts[index], length) == 0 {
                        return index
                    }
                }
                offset = position + 1
            }
            return nil
        }()
        return match.map { categoryIDs[$0] }
    }
}
