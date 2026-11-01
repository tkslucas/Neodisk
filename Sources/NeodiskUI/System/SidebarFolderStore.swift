// Seeded on first launch with the common folders; every entry is removable, and the common ones can be restored.

import Foundation
import NeodiskKit

struct SidebarFolderStore {
    private static let defaultsKey = "sidebarFolderPaths"
    /// Pre-2.11 key for user-added ("pinned") folders, folded into the seed
    /// once so upgrades keep the folders the user had.
    private static let legacyPinnedKey = "pinnedFolderPaths"
    private let defaults: UserDefaults
    /// The folders the section starts with (home, Desktop, …); anything else in it was added.
    let commonFolders: [ScanTarget]

    init(
        defaults: UserDefaults = .standard,
        commonFolders: [ScanTarget] = SystemIntegration.defaultFolderTargets()
    ) {
        self.defaults = defaults
        self.commonFolders = commonFolders
    }

    /// The key's presence is the seed flag: an existing empty array means
    /// the user removed everything, and it must stay empty across launches.
    func load() -> [ScanTarget] {
        if let paths = defaults.stringArray(forKey: Self.defaultsKey) {
            return targets(for: paths)
        }
        var paths = commonFolders.map(\.id)
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

    /// The common folders back on top in their order, the added ones kept after them.
    func restoreCommonFolders(keeping current: [ScanTarget]) -> [ScanTarget] {
        let commonIDs = Set(commonFolders.map(\.id))
        let paths = commonFolders.map(\.id) + current.map(\.id).filter { !commonIDs.contains($0) }
        defaults.set(paths, forKey: Self.defaultsKey)
        return targets(for: paths)
    }

    private func targets(for paths: [String]) -> [ScanTarget] {
        paths.map { path in
            ScanTarget(url: URL(filePath: path, directoryHint: .isDirectory))
        }
    }
}
