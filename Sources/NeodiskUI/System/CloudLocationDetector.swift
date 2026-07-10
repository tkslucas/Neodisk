//
//  CloudLocationDetector.swift
//  Neodisk
//
//  Detects cloud storage folders (iCloud Drive plus the File Provider roots
//  under ~/Library/CloudStorage) so they can appear as smart locations.
//

import Foundation
import NeodiskKit

enum CloudLocationDetector {
    /// File Provider folder-name prefixes (the part before the first "-")
    /// mapped to their user-facing provider names.
    private nonisolated static let providerNamesByPrefix: [String: String] = [
        "GoogleDrive": "Google Drive",
        "Dropbox": "Dropbox",
        "OneDrive": "OneDrive",
        "Box": "Box",
        "ProtonDrive": "Proton Drive",
    ]

    nonisolated static func detectedTargets(fileManager: FileManager = .default) -> [ScanTarget] {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let iCloudDocuments = URL(fileURLWithPath: ScanOptions.defaultICloudDriveRootPath, isDirectory: true)
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
        let cloudStorageRoot = URL(fileURLWithPath: ScanOptions.defaultCloudStorageRootPath, isDirectory: true)
        let legacyDropbox = homeDirectory.appending(path: "Dropbox", directoryHint: .isDirectory)

        let providerFolderNames = (try? fileManager.contentsOfDirectory(
            at: cloudStorageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent) ?? []

        return targets(
            iCloudDriveDocumentsURL: directoryExists(at: iCloudDocuments, fileManager: fileManager)
                ? iCloudDocuments
                : nil,
            cloudStorageRootURL: cloudStorageRoot,
            providerFolderNames: providerFolderNames,
            legacyDropboxURL: directoryExists(at: legacyDropbox, fileManager: fileManager)
                ? legacyDropbox
                : nil
        )
    }

    /// Pure core: builds the sidebar targets from what exists on disk.
    /// iCloud Drive comes first, then the File Provider folders sorted by
    /// display name. When several folders belong to the same provider (two
    /// Google accounts, say), each keeps its account suffix to stay
    /// distinguishable.
    nonisolated static func targets(
        iCloudDriveDocumentsURL: URL?,
        cloudStorageRootURL: URL,
        providerFolderNames: [String],
        legacyDropboxURL: URL?
    ) -> [ScanTarget] {
        var targets: [ScanTarget] = []

        if let iCloudDriveDocumentsURL {
            targets.append(namedTarget(url: iCloudDriveDocumentsURL, displayName: "iCloud Drive"))
        }

        var providerCounts: [String: Int] = [:]
        for folderName in providerFolderNames {
            providerCounts[providerName(forFolderName: folderName), default: 0] += 1
        }

        var providerTargets: [ScanTarget] = []
        for folderName in providerFolderNames {
            let provider = providerName(forFolderName: folderName)
            let accountSuffix = accountSuffix(ofFolderName: folderName)
            let displayName = providerCounts[provider, default: 0] > 1 && !accountSuffix.isEmpty
                ? "\(provider) (\(accountSuffix))"
                : provider
            let url = cloudStorageRootURL.appending(path: folderName, directoryHint: .isDirectory)
            providerTargets.append(namedTarget(url: url, displayName: displayName))
        }
        targets.append(contentsOf: providerTargets.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        })

        if let legacyDropboxURL {
            // A real pre-File-Provider Dropbox folder; when it is only a
            // symlink into ~/Library/CloudStorage, target normalization
            // resolves it and the caller's dedup drops the duplicate.
            targets.append(namedTarget(url: legacyDropboxURL, displayName: "Dropbox"))
        }

        return targets
    }

    /// Whether a path belongs to one of the cloud storage roots, so views
    /// can badge these locations without a new ScanTarget field.
    nonisolated static func isCloudPath(_ path: String) -> Bool {
        [ScanOptions.defaultCloudStorageRootPath, ScanOptions.defaultICloudDriveRootPath]
            .contains { path.hasPrefix($0 + "/") }
    }

    nonisolated static func providerName(forFolderName folderName: String) -> String {
        let prefix = folderName.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folderName
        return providerNamesByPrefix[prefix] ?? prefix
    }

    private nonisolated static func accountSuffix(ofFolderName folderName: String) -> String {
        let parts = folderName.split(separator: "-", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    private nonisolated static func namedTarget(url: URL, displayName: String) -> ScanTarget {
        let normalized = ScanTarget(url: url, kind: .folder)
        return ScanTarget(
            id: normalized.id,
            url: normalized.url,
            displayName: displayName,
            kind: .folder
        )
    }

    private nonisolated static func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
