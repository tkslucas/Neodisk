//
//  SidebarFolderStore.swift
//  Neodisk
//
//  The sidebar's Folders section, persisted across launches. Seeded on
//  first launch with the common folders (home, Desktop, Documents, …);
//  after that every entry — seeded or user-added — is an ordinary,
//  removable row. There is no separate "pinned" concept.
//

import Foundation
import NeodiskKit

struct SidebarFolderStore {
    private static let defaultsKey = "sidebarFolderPaths"
    /// Pre-2.11 key for user-added ("pinned") folders, folded into the seed
    /// once so upgrades keep the folders the user had.
    private static let legacyPinnedKey = "pinnedFolderPaths"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The key's presence is the seed flag: an existing empty array means
    /// the user removed everything, and it must stay empty across launches.
    func load() -> [ScanTarget] {
        if let paths = defaults.stringArray(forKey: Self.defaultsKey) {
            return targets(for: paths)
        }
        var paths = SystemIntegration.defaultFolderTargets().map(\.id)
        for legacy in defaults.stringArray(forKey: Self.legacyPinnedKey) ?? []
        where !paths.contains(legacy) {
            paths.append(legacy)
        }
        defaults.set(paths, forKey: Self.defaultsKey)
        return targets(for: paths)
    }

    func add(_ target: ScanTarget) {
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        guard !paths.contains(target.id) else { return }
        paths.append(target.id)
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    func remove(_ target: ScanTarget) {
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        paths.removeAll { $0 == target.id }
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    private func targets(for paths: [String]) -> [ScanTarget] {
        paths.map { path in
            ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
        }
    }
}
