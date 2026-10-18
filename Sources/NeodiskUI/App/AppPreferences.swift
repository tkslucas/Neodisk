// User-facing settings, persisted in UserDefaults; scan options map straight onto the engine's ScanOptions.

import AppKit
import SwiftUI
import TreemapKit
import NeodiskKit
import NeodiskAppModel

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

/// Defaults to waiting for an explicit rescan: opening a location should never start work the user didn't ask for.
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
    /// Display only: weights dataless files by cloud size instead of their ~0 on-disk size.
    @AppStorage("showCloudOnlyFiles") var showCloudOnlyFiles = true
    @AppStorage("showFreeSpace") var showFreeSpace = false
    /// The visualization color palette, by VizPalette id. Applies
    /// immediately; unknown ids fall back to the default (see VizPalette).
    @AppStorage("vizPalette") var vizPaletteID = VizPalette.standard.id
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
    /// Where the file outline docks (bottom table — the default — or the
    /// compact left column). See OutlinePosition.
    @AppStorage("outlinePosition") var outlinePositionRaw = OutlinePosition.bottom.rawValue
    /// Opts into the bottom table under the sunburst; it is never shown to the chart's left.
    @AppStorage("showFileListBelowSunburst") var showFileListBelowSunburst = false
    /// The bottom outline table's header sort (column + direction). The
    /// left column has no headers and ignores these.
    @AppStorage("outlineSortField") var outlineSortFieldRaw = OutlineSortField.size.rawValue
    @AppStorage("outlineSortAscending") var outlineSortAscending = false
    /// Decodes the previous snapshot whenever a complete tree lands, so Changes opens instantly. The key
    /// predates the restore trigger.
    @AppStorage("prepareChangesAfterScan") var prepareChangesAfterScan = true
    /// Off by default: hashing reads file contents, which costs real I/O and energy.
    @AppStorage("autoScanDuplicates") var autoScanDuplicates = false
    @AppStorage("hasSeenWelcome") var hasSeenWelcome = false
    /// A multiplier of the standard sizes; read through `textScale`, which snaps it to the ladder.
    @AppStorage("textScale") var textScaleRaw = TextScale.standard
    /// The user's changes to the Categories grouping, as
    /// FileCategoryCustomization JSON; "" for none.
    @AppStorage("fileCategories") var fileCategoriesJSON = ""

    /// Tests pass their own suite so writes never leak into real settings. Creation is launch, so the
    /// default-view preference is applied here, before the model binds and dev hooks override.
    init(defaults: UserDefaults? = nil) {
        defer {
            migrateColorblindToggle(in: defaults ?? .standard)
            applyDefaultVizView()
        }
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
        _vizPaletteID = AppStorage(
            wrappedValue: VizPalette.standard.id, "vizPalette", store: defaults
        )
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
        _outlinePositionRaw = AppStorage(
            wrappedValue: OutlinePosition.bottom.rawValue, "outlinePosition", store: defaults
        )
        _showFileListBelowSunburst = AppStorage(
            wrappedValue: false, "showFileListBelowSunburst", store: defaults
        )
        _outlineSortFieldRaw = AppStorage(
            wrappedValue: OutlineSortField.size.rawValue, "outlineSortField", store: defaults
        )
        _outlineSortAscending = AppStorage(
            wrappedValue: false, "outlineSortAscending", store: defaults
        )
        _prepareChangesAfterScan = AppStorage(
            wrappedValue: true, "prepareChangesAfterScan", store: defaults
        )
        _autoScanDuplicates = AppStorage(wrappedValue: false, "autoScanDuplicates", store: defaults)
        _hasSeenWelcome = AppStorage(wrappedValue: false, "hasSeenWelcome", store: defaults)
        _textScaleRaw = AppStorage(
            wrappedValue: TextScale.standard, "textScale", store: defaults
        )
        _fileCategoriesJSON = AppStorage(wrappedValue: "", "fileCategories", store: defaults)
    }

    /// The workspace text scale, always one of TextScale's steps.
    var textScale: Double {
        get { TextScale.snapped(textScaleRaw) }
        set { textScaleRaw = TextScale.snapped(newValue) }
    }

    var fileCategories: FileCategoryCustomization {
        get { FileCategoryCustomization(json: fileCategoriesJSON) }
        set { fileCategoriesJSON = newValue.json }
    }

    var theme: ThemePreference {
        get { ThemePreference(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    var vizPalette: VizPalette {
        get { VizPalette.named(vizPaletteID) }
        set { vizPaletteID = newValue.id }
    }

    /// Carries an enabled colorblind toggle (pre-2.53) over to the palette once; then the new key decides.
    private func migrateColorblindToggle(in defaults: UserDefaults) {
        guard defaults.object(forKey: "vizPalette") == nil,
              defaults.bool(forKey: "useColorblindPalette") else { return }
        vizPaletteID = VizPalette.colorblind.id
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

    /// Picking Sunburst leaves the treemap style alone, same as the toolbar picker.
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

    var outlinePosition: OutlinePosition {
        get { OutlinePosition(rawValue: outlinePositionRaw) ?? .bottom }
        set { outlinePositionRaw = newValue.rawValue }
    }

    var outlineSort: OutlineSort {
        get {
            OutlineSort(
                field: OutlineSortField(rawValue: outlineSortFieldRaw) ?? .size,
                ascending: outlineSortAscending
            )
        }
        set {
            outlineSortFieldRaw = newValue.field.rawValue
            outlineSortAscending = newValue.ascending
        }
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
        vizPaletteID = VizPalette.standard.id
        useScanExclusions = false
        exclusionPatternsText = ScanExclusionMatcher.commonPresetPatterns.joined(separator: "\n")
        autoRescanPolicyRaw = AutoRescanPolicy.snapshotOnly.rawValue
        defaultVizViewRaw = DefaultVizView.lastViewed.rawValue
        vizViewModeRaw = VizViewMode.treemap.rawValue
        treemapStyleRaw = TreemapStyle.cushion.rawValue
        showFileListBelowSunburst = false
        prepareChangesAfterScan = true
        autoScanDuplicates = false
        textScaleRaw = TextScale.standard
        fileCategoriesJSON = ""
    }
}
