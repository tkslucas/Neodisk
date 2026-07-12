//
//  ScanTarget.swift
//  Neodisk
//

import Foundation

public enum ScanTargetKind: String, Hashable, Codable, Sendable {
    case folder
    case volume
    /// A remote cloud-drive account (CloudScan). The target's id/url use the
    /// `cloudscan://` scheme, not a filesystem path.
    case cloud
}

public struct ScanTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let displayName: String
    public let kind: ScanTargetKind

    public nonisolated init(
        url: URL,
        kind: ScanTargetKind? = nil
    ) {
        let normalizedURL = ScanTarget.normalizedURL(from: url)
        self.id = normalizedURL.path
        self.url = normalizedURL
        self.displayName = ScanTarget.displayName(for: normalizedURL)
        self.kind = kind ?? ScanTarget.inferredKind(for: normalizedURL)
    }

    public nonisolated init(
        id: String,
        url: URL,
        displayName: String,
        kind: ScanTargetKind
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.kind = kind
    }

    private nonisolated static func normalizedURL(from url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        for syntheticPrefix in ["/.nofollow", "/.resolve"] {
            guard path == syntheticPrefix || path.hasPrefix(syntheticPrefix + "/") else { continue }

            let trimmedPath = String(path.dropFirst(syntheticPrefix.count))
            let normalizedPath = trimmedPath.isEmpty ? "/" : trimmedPath
            let syntheticResolvedURL = URL(
                fileURLWithPath: normalizedPath,
                isDirectory: standardizedURL.hasDirectoryPath
            )
            return normalizedRootURL(from: syntheticResolvedURL)
        }

        return normalizedRootURL(from: standardizedURL)
    }

    private nonisolated static func normalizedRootURL(from url: URL) -> URL {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: resolvedURL.path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    public nonisolated static func inferredKind(
        for url: URL,
        mountedVolumeURLs: [URL]? = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )
    ) -> ScanTargetKind {
        let path = url.standardizedFileURL.path
        if path == "/" {
            return .volume
        }

        guard let mountedVolumeURLs else {
            return .folder
        }

        let mountedVolumePaths = Set(mountedVolumeURLs.map { $0.standardizedFileURL.path })
        return mountedVolumePaths.contains(path) ? .volume : .folder
    }

    public nonisolated static func displayName(for url: URL) -> String {
        if url.path == "/" {
            do {
                let volumeName = try url.resourceValues(forKeys: [.volumeNameKey]).volumeName
                return volumeName ?? "Startup Disk"
            } catch {
                return "Startup Disk"
            }
        }

        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }
}

public nonisolated struct ScanOptions: Hashable, Codable, Sendable {
    /// Engine tuning knobs, grouped so the everyday options stay readable.
    /// Every knob is an override; nil picks the engine's hardware-aware
    /// default.
    public nonisolated struct Tuning: Hashable, Codable, Sendable {
        /// Minimum file count to trigger auto-summarization (default 5,000).
        public var autoSummarizeMinFileCount: Int?
        /// Maximum average file size to trigger auto-summarization (default 4 KB).
        public var autoSummarizeMaxAverageFileSize: Int64?
        /// Minimum depth at which auto-summarization applies (default 2).
        public var autoSummarizeMinDepthForSummarization: Int?
        /// Bounded package/atomic summary parallelism.
        public var atomicSummaryWorkerLimit: Int?
        /// Bounded immediate-child metadata classification.
        public var directoryClassificationWorkerLimit: Int?
        /// Bounded ordinary directory traversal parallelism.
        public var directoryTraversalWorkerLimit: Int?

        public nonisolated init(
            autoSummarizeMinFileCount: Int? = nil,
            autoSummarizeMaxAverageFileSize: Int64? = nil,
            autoSummarizeMinDepthForSummarization: Int? = nil,
            atomicSummaryWorkerLimit: Int? = nil,
            directoryClassificationWorkerLimit: Int? = nil,
            directoryTraversalWorkerLimit: Int? = nil
        ) {
            self.autoSummarizeMinFileCount = autoSummarizeMinFileCount
            self.autoSummarizeMaxAverageFileSize = autoSummarizeMaxAverageFileSize
            self.autoSummarizeMinDepthForSummarization = autoSummarizeMinDepthForSummarization
            self.atomicSummaryWorkerLimit = atomicSummaryWorkerLimit
            self.directoryClassificationWorkerLimit = directoryClassificationWorkerLimit
            self.directoryTraversalWorkerLimit = directoryTraversalWorkerLimit
        }
    }

    public var includeHiddenFiles = false
    public var treatPackagesAsDirectories = false
    /// Traverses the scan root even when it is a package, while packages
    /// below it stay opaque leaves. This is how "Show Package Contents"
    /// expands one package in place without also opening every bundle
    /// nested inside it.
    public var treatRootPackageAsDirectory = false
    public var autoSummarizeDirectories = true
    public var includeCloudStorage = false
    public var cloudStorageRootPath = ScanOptions.defaultCloudStorageRootPath
    public var iCloudDriveRootPath = ScanOptions.defaultICloudDriveRootPath
    public var exclusionPatterns: [String] = []
    public var exclusionRootPath: String?
    public var tuning = Tuning()

    public nonisolated init(
        includeHiddenFiles: Bool = false,
        treatPackagesAsDirectories: Bool = false,
        treatRootPackageAsDirectory: Bool = false,
        autoSummarizeDirectories: Bool = true,
        includeCloudStorage: Bool = false,
        cloudStorageRootPath: String = ScanOptions.defaultCloudStorageRootPath,
        iCloudDriveRootPath: String = ScanOptions.defaultICloudDriveRootPath,
        exclusionPatterns: [String] = [],
        exclusionRootPath: String? = nil,
        tuning: Tuning = Tuning()
    ) {
        self.includeHiddenFiles = includeHiddenFiles
        self.treatPackagesAsDirectories = treatPackagesAsDirectories
        self.treatRootPackageAsDirectory = treatRootPackageAsDirectory
        self.autoSummarizeDirectories = autoSummarizeDirectories
        self.includeCloudStorage = includeCloudStorage
        self.cloudStorageRootPath = cloudStorageRootPath
        self.iCloudDriveRootPath = iCloudDriveRootPath
        self.exclusionPatterns = exclusionPatterns
        self.exclusionRootPath = exclusionRootPath
        self.tuning = tuning
    }

    public nonisolated static let defaultCloudStorageRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        .standardizedFileURL
        .path

    public nonisolated static let defaultICloudDriveRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        .standardizedFileURL
        .path
}
