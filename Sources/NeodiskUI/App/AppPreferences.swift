//
//  AppPreferences.swift
//  Neodisk
//
//  User-facing settings, persisted in UserDefaults. Kept deliberately small:
//  the app follows system appearance unless overridden, and scan options map
//  straight onto the engine's ScanOptions.
//

import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// What happens when a location with a cached snapshot is opened from the
/// sidebar: refresh it right away, decide from the last scan's duration,
/// or always wait for an explicit rescan (the default — opening a location
/// should never start work the user didn't ask for).
enum AutoRescanPolicy: String, CaseIterable, Identifiable {
    case automatic
    case smart
    case snapshotOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Rescan automatically"
        case .smart: return "Smart"
        case .snapshotOnly: return "Show snapshot only"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @AppStorage("themePreference") var themeRaw = ThemePreference.system.rawValue {
        didSet { applyTheme() }
    }
    @AppStorage("includeHiddenFiles") var includeHiddenFiles = true
    @AppStorage("autoSummarizeDirectories") var autoSummarizeDirectories = true
    @AppStorage("includeCloudStorage") var includeCloudStorage = true
    /// Weight cloud files that are not downloaded (dataless) by their cloud
    /// size in the visualizations, instead of their ~0 on-disk size. Display
    /// only — a no-op for scans without cloud items.
    @AppStorage("showCloudOnlyFiles") var showCloudOnlyFiles = true
    @AppStorage("showFreeSpace") var showFreeSpace = false
    /// Swap the visualization's kind/age colors for a colorblind-safe palette
    /// (Okabe-Ito + viridis). Applies immediately; see VizPalette.
    @AppStorage("useColorblindPalette") var useColorblindPalette = false
    @AppStorage("useScanExclusions") var useScanExclusions = false
    /// One glob-style pattern per line (same syntax as .gitignore-lite:
    /// trailing "/" matches directories, "*" wildcards within a component).
    @AppStorage("exclusionPatternsText") var exclusionPatternsText =
        ScanExclusionMatcher.commonPresetPatterns.joined(separator: "\n")
    @AppStorage("autoRescanPolicy") var autoRescanPolicyRaw = AutoRescanPolicy.snapshotOnly.rawValue
    /// Which view a new session opens with; `vizViewMode`/`treemapStyle`
    /// track the current view, this decides whether launch keeps them.
    @AppStorage("defaultVizView") var defaultVizViewRaw = DefaultVizView.lastViewed.rawValue
    /// Which visualization fills the center pane (treemap or sunburst).
    @AppStorage("vizViewMode") var vizViewModeRaw = VizViewMode.treemap.rawValue
    /// How the treemap draws: classic cushion shading, or the flat
    /// nested-box style. See TreemapStyle.
    @AppStorage("treemapStyle") var treemapStyleRaw = TreemapStyle.cushion.rawValue
    /// Decode the previous snapshot whenever a complete tree lands on screen
    /// — a scan finishing, or a saved snapshot opening without a rescan — so
    /// the Changes toggle shows instantly instead of loading on click. The
    /// storage key predates the restore trigger.
    @AppStorage("prepareChangesAfterScan") var prepareChangesAfterScan = true
    /// Start the duplicate content scan whenever a complete tree lands on
    /// screen (scan finish or snapshot restore). Off by default: hashing
    /// reads file contents, which costs real I/O and energy.
    @AppStorage("autoScanDuplicates") var autoScanDuplicates = false
    @AppStorage("hasSeenWelcome") var hasSeenWelcome = false

    /// Backing store defaults to UserDefaults.standard; tests pass their
    /// own suite so preference writes never leak into real settings.
    /// Creation is launch: the default-view preference is applied on the
    /// way out (before the model binds and before dev hooks override).
    init(defaults: UserDefaults? = nil) {
        defer { applyDefaultVizView() }
        guard let defaults else { return }
        _themeRaw = AppStorage(
            wrappedValue: ThemePreference.system.rawValue, "themePreference", store: defaults
        )
        _includeHiddenFiles = AppStorage(wrappedValue: true, "includeHiddenFiles", store: defaults)
        _autoSummarizeDirectories = AppStorage(
            wrappedValue: true, "autoSummarizeDirectories", store: defaults
        )
        _includeCloudStorage = AppStorage(wrappedValue: true, "includeCloudStorage", store: defaults)
        _showCloudOnlyFiles = AppStorage(wrappedValue: true, "showCloudOnlyFiles", store: defaults)
        _showFreeSpace = AppStorage(wrappedValue: false, "showFreeSpace", store: defaults)
        _useColorblindPalette = AppStorage(wrappedValue: false, "useColorblindPalette", store: defaults)
        _useScanExclusions = AppStorage(wrappedValue: false, "useScanExclusions", store: defaults)
        _exclusionPatternsText = AppStorage(
            wrappedValue: ScanExclusionMatcher.commonPresetPatterns.joined(separator: "\n"),
            "exclusionPatternsText",
            store: defaults
        )
        _autoRescanPolicyRaw = AppStorage(
            wrappedValue: AutoRescanPolicy.snapshotOnly.rawValue, "autoRescanPolicy", store: defaults
        )
        _defaultVizViewRaw = AppStorage(
            wrappedValue: DefaultVizView.lastViewed.rawValue, "defaultVizView", store: defaults
        )
        _vizViewModeRaw = AppStorage(
            wrappedValue: VizViewMode.treemap.rawValue, "vizViewMode", store: defaults
        )
        _treemapStyleRaw = AppStorage(
            wrappedValue: TreemapStyle.cushion.rawValue, "treemapStyle", store: defaults
        )
        _prepareChangesAfterScan = AppStorage(
            wrappedValue: true, "prepareChangesAfterScan", store: defaults
        )
        _autoScanDuplicates = AppStorage(wrappedValue: false, "autoScanDuplicates", store: defaults)
        _hasSeenWelcome = AppStorage(wrappedValue: false, "hasSeenWelcome", store: defaults)
    }

    var theme: ThemePreference {
        get { ThemePreference(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    var autoRescanPolicy: AutoRescanPolicy {
        get { AutoRescanPolicy(rawValue: autoRescanPolicyRaw) ?? .snapshotOnly }
        set { autoRescanPolicyRaw = newValue.rawValue }
    }

    var defaultVizView: DefaultVizView {
        get { DefaultVizView(rawValue: defaultVizViewRaw) ?? .lastViewed }
        set { defaultVizViewRaw = newValue.rawValue }
    }

    var vizViewMode: VizViewMode {
        get { VizViewMode(rawValue: vizViewModeRaw) ?? .treemap }
        set { vizViewModeRaw = newValue.rawValue }
    }

    /// Launch: unless the default is "last viewed", override the persisted
    /// current-view pair with the chosen default. Picking Sunburst leaves
    /// the treemap style alone, same as the toolbar picker.
    func applyDefaultVizView() {
        switch defaultVizView {
        case .lastViewed:
            break
        case .cushionTreemap:
            vizViewMode = .treemap
            treemapStyle = .cushion
        case .flatTreemap:
            vizViewMode = .treemap
            treemapStyle = .flat
        case .sunburst:
            vizViewMode = .sunburst
        }
    }

    var treemapStyle: TreemapStyle {
        get { TreemapStyle(rawValue: treemapStyleRaw) ?? .cushion }
        set { treemapStyleRaw = newValue.rawValue }
    }

    /// Patterns parsed from the exclusions text, empty when disabled.
    var activeExclusionPatterns: [String] {
        guard useScanExclusions else { return [] }
        return exclusionPatternsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Scan options reflecting the current preferences.
    var scanOptions: ScanOptions {
        var options = ScanOptions()
        options.includeHiddenFiles = includeHiddenFiles
        options.autoSummarizeDirectories = autoSummarizeDirectories
        options.includeCloudStorage = includeCloudStorage
        options.exclusionPatterns = activeExclusionPatterns
        return options
    }

    func applyTheme() {
        // NSApp is nil in test processes that never boot AppKit.
        NSApp?.appearance = theme.appearance
    }

    func restoreDefaults() {
        themeRaw = ThemePreference.system.rawValue
        includeHiddenFiles = true
        autoSummarizeDirectories = true
        includeCloudStorage = true
        showCloudOnlyFiles = true
        showFreeSpace = false
        useColorblindPalette = false
        useScanExclusions = false
        exclusionPatternsText = ScanExclusionMatcher.commonPresetPatterns.joined(separator: "\n")
        autoRescanPolicyRaw = AutoRescanPolicy.snapshotOnly.rawValue
        defaultVizViewRaw = DefaultVizView.lastViewed.rawValue
        vizViewModeRaw = VizViewMode.treemap.rawValue
        treemapStyleRaw = TreemapStyle.cushion.rawValue
        prepareChangesAfterScan = true
        autoScanDuplicates = false
    }
}
