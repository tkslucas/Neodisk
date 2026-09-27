//
//  Preferences.swift
//  NeodiskGTK
//
//  Persisted settings for the Linux app: a JSON file in the XDG config
//  directory ($XDG_CONFIG_HOME/neodisk/settings.json), the Linux analog of
//  the macOS app's UserDefaults domain. Defaults match the macOS app's.
//  GSettings would need a schema compiled into the system before the app
//  could run, which rules out `swift run` from a checkout.
//

import Foundation
import NeodiskAppModel
import NeodiskKit
import Observation
import TreemapKit

@MainActor
@Observable
final class Preferences {
    enum ColorScheme: String, Codable, CaseIterable {
        case system, light, dark
    }

    var colorScheme: ColorScheme = .system { didSet { scheduleSave() } }
    var includeHiddenFiles = true { didSet { scheduleSave() } }
    var autoSummarizeDirectories = true { didSet { scheduleSave() } }
    var showFreeSpace = false { didSet { scheduleSave() } }
    var paletteID = VizPalette.standard.id { didSet { scheduleSave() } }
    var vizMode: VizViewMode = .treemap { didSet { scheduleSave() } }
    var treemapStyle: TreemapStyle = .cushion { didSet { scheduleSave() } }
    var kindMode: FileKindDisplayMode = .categories { didSet { scheduleSave() } }
    var showsStatistics = true { didSet { scheduleSave() } }
    var showsOutline = true { didSet { scheduleSave() } }
    /// Folders the user scanned or pinned, most recent first — the
    /// sidebar's Recents, and the snapshot cache's keep list.
    var recentFolders: [String] = [] { didSet { scheduleSave() } }
    var windowWidth = 1280 { didSet { scheduleSave() } }
    var windowHeight = 820 { didSet { scheduleSave() } }

    var palette: VizPalette { VizPalette.named(paletteID) }

    /// The effective scan options behind every scan the app starts.
    var scanOptions: ScanOptions {
        var options = ScanOptions()
        options.includeHiddenFiles = includeHiddenFiles
        options.autoSummarizeDirectories = autoSummarizeDirectories
        return options
    }

    static let maximumRecentFolders = 12

    func noteRecentFolder(_ path: String) {
        var folders = recentFolders.filter { $0 != path }
        folders.insert(path, at: 0)
        recentFolders = Array(folders.prefix(Self.maximumRecentFolders))
    }

    // MARK: - Persistence

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL = Preferences.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return configHome.appending(path: "neodisk/settings.json")
    }

    private struct Stored: Codable {
        var colorScheme: ColorScheme?
        var includeHiddenFiles: Bool?
        var autoSummarizeDirectories: Bool?
        var showFreeSpace: Bool?
        var paletteID: String?
        var vizMode: String?
        var treemapStyle: String?
        var kindMode: String?
        var showsStatistics: Bool?
        var showsOutline: Bool?
        var recentFolders: [String]?
        var windowWidth: Int?
        var windowHeight: Int?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        if let value = stored.colorScheme { colorScheme = value }
        if let value = stored.includeHiddenFiles { includeHiddenFiles = value }
        if let value = stored.autoSummarizeDirectories { autoSummarizeDirectories = value }
        if let value = stored.showFreeSpace { showFreeSpace = value }
        if let value = stored.paletteID { paletteID = value }
        if let value = stored.vizMode.flatMap(VizViewMode.init(rawValue:)) { vizMode = value }
        if let value = stored.treemapStyle.flatMap(TreemapStyle.init(rawValue:)) { treemapStyle = value }
        if let value = stored.kindMode.flatMap(FileKindDisplayMode.init(rawValue:)) { kindMode = value }
        if let value = stored.showsStatistics { showsStatistics = value }
        if let value = stored.showsOutline { showsOutline = value }
        if let value = stored.recentFolders { recentFolders = value }
        if let value = stored.windowWidth { windowWidth = value }
        if let value = stored.windowHeight { windowHeight = value }
    }

    /// Coalesces a burst of changes (a window resize) into one write.
    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let stored = Stored(
            colorScheme: colorScheme,
            includeHiddenFiles: includeHiddenFiles,
            autoSummarizeDirectories: autoSummarizeDirectories,
            showFreeSpace: showFreeSpace,
            paletteID: paletteID,
            vizMode: vizMode.rawValue,
            treemapStyle: treemapStyle.rawValue,
            kindMode: kindMode.rawValue,
            showsStatistics: showsStatistics,
            showsOutline: showsOutline,
            recentFolders: recentFolders,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
