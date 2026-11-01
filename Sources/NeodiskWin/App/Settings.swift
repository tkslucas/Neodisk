// Settings as JSON in %APPDATA%\Neodisk\settings.json, with the Linux app's key names where the setting is
// the same, so the two stay easy to compare.

import Foundation
import NeodiskAppModel
import NeodiskKit
import Observation
import TreemapKit

@MainActor
@Observable
final class Settings {
    var includeHiddenFiles = true { didSet { scheduleSave() } }
    var autoSummarizeDirectories = true { didSet { scheduleSave() } }
    var paletteID = VizPalette.standard.id { didSet { scheduleSave() } }
    var vizMode: VizViewMode = .treemap { didSet { scheduleSave() } }
    var treemapStyle: TreemapStyle = .cushion { didSet { scheduleSave() } }
    /// Folders the user scanned, most recent first: the pane's Folders section and the snapshot cache's keep list.
    var recentFolders: [String] = [] { didSet { scheduleSave() } }
    /// The window's size in DIPs (restored, not maximized).
    var windowWidth = 1280 { didSet { scheduleSave() } }
    var windowHeight = 820 { didSet { scheduleSave() } }
    var windowMaximized = false { didSet { scheduleSave() } }

    var palette: VizPalette { VizPalette.named(paletteID) }

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

    init(fileURL: URL = Settings.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["APPDATA"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "AppData/Roaming", directoryHint: .isDirectory)
        return base.appending(path: "\(AppChannel.current.appName)/settings.json")
    }

    private struct Stored: Codable {
        var includeHiddenFiles: Bool?
        var autoSummarizeDirectories: Bool?
        var paletteID: String?
        var vizMode: String?
        var treemapStyle: String?
        var recentFolders: [String]?
        var windowWidth: Int?
        var windowHeight: Int?
        var windowMaximized: Bool?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        if let value = stored.includeHiddenFiles { includeHiddenFiles = value }
        if let value = stored.autoSummarizeDirectories { autoSummarizeDirectories = value }
        if let value = stored.paletteID { paletteID = value }
        if let value = stored.vizMode.flatMap(VizViewMode.init(rawValue:)) { vizMode = value }
        if let value = stored.treemapStyle.flatMap(TreemapStyle.init(rawValue:)) { treemapStyle = value }
        if let value = stored.recentFolders { recentFolders = value }
        if let value = stored.windowWidth { windowWidth = value }
        if let value = stored.windowHeight { windowHeight = value }
        if let value = stored.windowMaximized { windowMaximized = value }
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
            includeHiddenFiles: includeHiddenFiles,
            autoSummarizeDirectories: autoSummarizeDirectories,
            paletteID: paletteID,
            vizMode: vizMode.rawValue,
            treemapStyle: treemapStyle.rawValue,
            recentFolders: recentFolders,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            windowMaximized: windowMaximized
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
