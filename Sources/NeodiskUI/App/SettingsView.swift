//
//  SettingsView.swift
//  Neodisk
//
//  Settings window (⌘,): General (appearance, updates, workspace), View
//  (visualization), Advanced (scanning, results, exclusions) and Privacy
//  (Full Disk Access status).
//

import SwiftUI
import TreemapKit
import NeodiskKit

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

            PrivacySettingsTab(model: model)
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
                    Text("Neodisk checks GitHub for new versions in the background and always asks before installing anything.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
            Section("Visualization") {
                Picker("Default view", selection: Binding(
                    get: { preferences.defaultVizView },
                    set: { preferences.defaultVizView = $0 }
                )) {
                    Text("Last viewed").tag(DefaultVizView.lastViewed)
                    Text("Cushion Treemap").tag(DefaultVizView.cushionTreemap)
                    Text("Flat Treemap").tag(DefaultVizView.flatTreemap)
                    Text("Sunburst").tag(DefaultVizView.sunburst)
                }
                Text("The view the app starts in. Last viewed restores whatever was on screen when you quit. The toolbar picker switches views any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Show free space in treemap", isOn: $preferences.showFreeSpace)
                Text("The sunburst always shows free and hidden space for volume scans; this adds them to the treemap too. Hidden space is capacity the scan could not see, such as purgeable space and local snapshots. Applies immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Use colorblind-safe colors", isOn: $preferences.useColorblindPalette)
                Text("Swaps the file-kind and age colors for a palette that stays distinct with common color vision differences. Applies immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                Text("Mounted volume scans always include hidden files automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Automatically summarize folders with many small files",
                    isOn: $preferences.autoSummarizeDirectories
                )
                Text("Summarizing folders with thousands of tiny files (like node_modules or caches) dramatically improves scan speed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Scan local cloud files", isOn: $preferences.includeCloudStorage)
                Text("When off, scans skip locally synced cloud folders: ~/Library/CloudStorage (Google Drive, Dropbox, OneDrive) and iCloud Drive. Connected cloud drive accounts are not affected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Changes apply to the next scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("When opening a scanned location", selection: Binding(
                    get: { preferences.autoRescanPolicy },
                    set: { preferences.autoRescanPolicy = $0 }
                )) {
                    ForEach(AutoRescanPolicy.allCases) { policy in
                        Text(LocalizedStringKey(policy.title)).tag(policy)
                    }
                }
                Text("Rescan automatically always refreshes behind the saved results; Smart skips the refresh when the last scan took a while; Show snapshot only always waits for Rescan Now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("When Results Appear") {
                Toggle(
                    "Prepare the Changes comparison in the background",
                    isOn: $preferences.prepareChangesAfterScan
                )
                Text("Loads the previous scan in the background so the Changes view opens instantly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Find duplicate files automatically", isOn: $preferences.autoScanDuplicates)
                Text("Runs the duplicate scan automatically when results appear. Reading file contents can take time and energy on large locations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    @State private var accessStatus: FullDiskAccessStatus = .unknown
    @State private var snapshotCacheSize: Int64?

    var body: some View {
        Form {
            Section("Full Disk Access") {
                Text("Neodisk can scan ordinary folders immediately. For protected macOS locations such as Mail, Safari, Messages, and Library content, grant Full Disk Access in System Settings.")
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

                // Only relevant to dev builds launched via `swift run`, which
                // have no app bundle (hence no CFBundleIdentifier). Packaged
                // .apps get their own TCC entry, so this note would just confuse.
                if Bundle.main.bundleIdentifier == nil {
                    Text("Note: running unbundled (swift run), Neodisk inherits its permissions from the terminal that launched it — grant Full Disk Access to that terminal app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Read-Only Guarantee") {
                Text("Neodisk is a viewer: it never modifies or deletes files, and has no delete function at all. To remove something, use Reveal in Finder and delete it there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar Folders") {
                Text("Folders you add are stored locally so they can appear in the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear Added Folders") {
                    model.removeSidebarFolders(ids: Set(model.sidebarFolders.map(\.id)))
                    refreshSnapshotCacheSize()
                }
                .disabled(model.sidebarFolders.isEmpty)
            }

            Section("Scan Snapshots") {
                Text("After each completed scan, Neodisk keeps the latest results for that location on this Mac so reopening it shows the last scan instantly while a fresh scan runs. Snapshots contain file names, paths, and sizes; they are stored only in Neodisk's local cache and never leave this Mac.")
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
