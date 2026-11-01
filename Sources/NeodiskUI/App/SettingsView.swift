// Settings window (⌘,): General (appearance, updates, workspace), View (visualization), Advanced (scanning,
// results, exclusions) and Privacy (Full Disk Access status).

import SwiftUI
import TreemapKit
import NeodiskKit
import NeodiskAppModel

struct SettingsView: View {
    let model: NeodiskViewModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var updates: UpdateController

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model, preferences: preferences, updates: updates)
                .tabItem { Label("General", systemImage: "gearshape") }

            ViewSettingsTab(preferences: preferences)
                .tabItem { Label("View", systemImage: "eye") }

            AdvancedSettingsTab(preferences: preferences)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }

            PrivacySettingsTab(model: model, preferences: preferences)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let model: NeodiskViewModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var updates: UpdateController

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { preferences.theme },
                    set: { preferences.theme = $0 }
                )) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(LocalizedStringKey(theme.title)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Updates") {
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .disabled(!updates.isSupported)
                if updates.isSupported {
                    Button("Check for Updates…") {
                        updates.checkForUpdates()
                    }
                    .disabled(!updates.canCheckForUpdates)
                } else {
                    // Unbundled `swift run` builds and bundles without an
                    // appcast feed cannot update themselves.
                    Text("Automatic updates work only in the packaged app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Workspace") {
                Button("Show Welcome Screen") {
                    model.showWelcomeSheet = true
                }
                Button("Restore Defaults") {
                    preferences.restoreDefaults()
                    model.restoreCommonSidebarFolders()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - View

private struct ViewSettingsTab: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Text Size") {
                Picker("Size", selection: Binding(
                    get: { preferences.textScale },
                    set: { preferences.textScale = $0 }
                )) {
                    ForEach(TextScale.steps, id: \.self) { step in
                        Text(verbatim: TextScale.title(for: step)).tag(step)
                    }
                }
            }

            Section("Visualization") {
                Picker("Default view", selection: Binding(
                    get: { preferences.defaultVizView },
                    set: { preferences.defaultVizView = $0 }
                )) {
                    Text("Last viewed").tag(DefaultVizView.lastViewed)
                    // Only views the toolbar shows; hiding the default one resets it to Last viewed.
                    ForEach(preferences.workspaceLayout.views.visible, id: \.self) { view in
                        Text(view.menuTitle).tag(DefaultVizView(view))
                    }
                }

                Toggle("Show free space in treemap", isOn: $preferences.showFreeSpace)
                    .neoHelp("Adds hidden space too: capacity the scan could not see, such as purgeable space and local snapshots.")

                Picker("Color palette", selection: $preferences.vizPaletteID) {
                    ForEach(VizPalette.all) { palette in
                        Text(LocalizedStringKey(palette.title)).tag(palette.id)
                    }
                }
            }

            Section("File Categories") {
                Button("Reset Categories") {
                    preferences.fileCategoriesJSON = ""
                }
                .neoHelp("To move a file type to another category or a new one, group the Kinds tab by Types and right-click the type. Right-click a category you made to rename or delete it.")
                .disabled(preferences.fileCategoriesJSON.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Show hidden files while scanning", isOn: $preferences.includeHiddenFiles)
                Toggle(
                    "Automatically summarize folders with many small files",
                    isOn: $preferences.autoSummarizeDirectories
                )
                Toggle("Scan local cloud files", isOn: $preferences.includeCloudStorage)
                    .neoHelp("When off, scans skip locally synced cloud folders: ~/Library/CloudStorage (Google Drive, Dropbox, OneDrive) and iCloud Drive.")
                Picker("When opening a scanned location", selection: Binding(
                    get: { preferences.autoRescanPolicy },
                    set: { preferences.autoRescanPolicy = $0 }
                )) {
                    ForEach(AutoRescanPolicy.allCases) { policy in
                        Text(LocalizedStringKey(policy.title)).tag(policy)
                    }
                }
                .neoHelp("Rescan automatically always refreshes behind the saved results; Smart skips the refresh when the last scan took a while; Show snapshot only always waits for Rescan Now.")
            }

            Section("When Results Appear") {
                Toggle(
                    "Prepare the Changes comparison in the background",
                    isOn: $preferences.prepareChangesAfterScan
                )
                Toggle("Find duplicate files automatically", isOn: $preferences.autoScanDuplicates)
                    .neoHelp("Reading file contents can take time and energy on large locations.")
            }

            Section("Exclusions") {
                Toggle("Use scan exclusions", isOn: $preferences.useScanExclusions)
                TextEditor(text: $preferences.exclusionPatternsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 96)
                    .disabled(!preferences.useScanExclusions)
                    .opacity(preferences.useScanExclusions ? 1 : 0.5)
                HStack {
                    Text("One pattern per line. Trailing “/” matches folders; “*” is a wildcard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Presets") {
                        addPresetPatterns()
                    }
                    .disabled(!preferences.useScanExclusions)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addPresetPatterns() {
        var lines = preferences.exclusionPatternsText
            .split(separator: "\n")
            .map(String.init)
        for preset in ScanExclusionMatcher.commonPresetPatterns where !lines.contains(preset) {
            lines.append(preset)
        }
        preferences.exclusionPatternsText = lines.joined(separator: "\n")
    }
}

// MARK: - Privacy

private struct PrivacySettingsTab: View {
    let model: NeodiskViewModel
    @ObservedObject var preferences: AppPreferences

    @State private var accessStatus: FullDiskAccessStatus = .unknown
    @State private var snapshotCacheSize: Int64?
    @State private var confirmsClearingFolders = false

    var body: some View {
        Form {
            Section("Full Disk Access") {
                Text("For protected macOS locations such as Mail, Safari, Messages, and Library content, grant Full Disk Access in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    switch accessStatus {
                    case .granted:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Full Disk Access is enabled.").foregroundStyle(.green)
                    case .notGranted:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                        Text("Full Disk Access is not enabled.")
                    case .unknown:
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Open Full Disk Access Settings") {
                        _ = SystemIntegration.prepareAndOpenFullDiskAccessSettings()
                    }
                    Button("Recheck") {
                        recheck()
                    }
                }

                // Only `swift run` builds (no bundle id) inherit the terminal's permissions; packaged apps get
                // their own TCC entry.
                if Bundle.main.bundleIdentifier == nil {
                    Text("Note: running unbundled (swift run), Neodisk inherits its permissions from the terminal that launched it — grant Full Disk Access to that terminal app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Moving to the Trash") {
                Toggle("Allow moving items to the Trash", isOn: $preferences.allowsMovingToTrash)
                Text("Neodisk never deletes anything itself, and won't touch system folders or your home folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar Folders") {
                HStack {
                    Button("Clear Added Folders") {
                        confirmsClearingFolders = true
                    }
                    .disabled(model.addedSidebarFolders.isEmpty)
                    Button("Restore Default Folders") {
                        model.restoreCommonSidebarFolders()
                    }
                    .disabled(!model.isMissingCommonSidebarFolders)
                }
                .confirmationDialog(
                    "Remove the folders you added from the sidebar?",
                    isPresented: $confirmsClearingFolders
                ) {
                    Button("Clear Added Folders", role: .destructive) {
                        model.removeAddedSidebarFolders()
                        refreshSnapshotCacheSize()
                    }
                } message: {
                    Text("Their scan snapshots are removed too.")
                }
            }

            Section("Scan Snapshots") {
                Text("Snapshots contain file names, paths, and sizes; they are stored only in Neodisk's local cache and never leave this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Size on disk") {
                    Text(snapshotCacheSize.map { NeodiskFormatters.size($0) }
                        ?? NSLocalizedString("Calculating…", comment: "Snapshot cache size placeholder while it is being computed"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Clear Scan Snapshots") {
                    Task {
                        await model.session.clearScanSnapshots()
                        refreshSnapshotCacheSize()
                    }
                }
                .disabled(snapshotCacheSize == 0)
            }
        }
        .formStyle(.grouped)
        .task {
            recheck()
            refreshSnapshotCacheSize()
        }
    }

    private func refreshSnapshotCacheSize() {
        Task {
            snapshotCacheSize = await model.session.scanSnapshotCacheSize()
        }
    }

    private func recheck() {
        accessStatus = .unknown
        Task {
            let status = await Task.detached(priority: .utility) {
                SystemIntegration.fullDiskAccessStatus()
            }.value
            accessStatus = status
        }
    }
}
