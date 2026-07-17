//
//  ScanMetadataLoader.swift
//  Neodisk
//

import Darwin
import Foundation

nonisolated final class LinkCountCapabilityCache: @unchecked Sendable {
    nonisolated struct ProbeResult: Sendable {
        let volumeRootPath: String?
        let supportsHardLinks: Bool?
        #if DEBUG
        let errorDescription: String?
        #endif

        init(
            volumeRootPath: String?,
            supportsHardLinks: Bool?,
            errorDescription: String? = nil
        ) {
            self.volumeRootPath = volumeRootPath
            self.supportsHardLinks = supportsHardLinks
            #if DEBUG
            self.errorDescription = errorDescription
            #endif
        }
    }

    typealias ProbeProvider = @Sendable (URL) -> ProbeResult

    private let lock = NSLock()
    private let probeProvider: ProbeProvider
    private var requiresFileSystemInfoByRootPath: [String: Bool] = [:]

    init(probeProvider: @escaping ProbeProvider = LinkCountCapabilityCache.defaultProbe) {
        self.probeProvider = probeProvider
    }

    func requiresFileSystemInfoWhenLinkCountMissing(for url: URL, diagnostics: ScanDiagnosticsContext?) -> Bool {
        let path = Self.standardizedPath(for: url)
        lock.lock()
        if let cachedRequirement = cachedRequirementLocked(for: path) {
            lock.unlock()
            return cachedRequirement
        }
        lock.unlock()

        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let probe = probeProvider(url)
        let requiresFileSystemInfo = probe.supportsHardLinks != false
        if let rootPath = Self.cacheRootPath(for: probe, path: path) {
            lock.lock()
            requiresFileSystemInfoByRootPath[rootPath] = requiresFileSystemInfo
            lock.unlock()
        }

        #if DEBUG
        diagnostics?.record(
            operation: "metadata.link_count_capability_probe",
            url: url,
            startedAt: start,
            detail: Self.diagnosticDetail(for: probe, requiresFileSystemInfo: requiresFileSystemInfo)
        )
        #endif
        return requiresFileSystemInfo
    }

    private func cachedRequirementLocked(for path: String) -> Bool? {
        var bestMatch: (rootLength: Int, requiresFileSystemInfo: Bool)?
        for (rootPath, requiresFileSystemInfo) in requiresFileSystemInfoByRootPath
        where Self.path(path, isUnder: rootPath) {
            if bestMatch == nil || rootPath.count > bestMatch!.rootLength {
                bestMatch = (rootPath.count, requiresFileSystemInfo)
            }
        }
        return bestMatch?.requiresFileSystemInfo
    }

    private static func defaultProbe(for url: URL) -> ProbeResult {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeURLKey,
                .volumeSupportsHardLinksKey
            ])
            return ProbeResult(
                volumeRootPath: values.volume?.standardizedFileURL.path,
                supportsHardLinks: values.volumeSupportsHardLinks
            )
        } catch {
            #if DEBUG
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil,
                errorDescription: ScanWarningFactory.diagnosticErrorDescription(error)
            )
            #else
            return ProbeResult(
                volumeRootPath: nil,
                supportsHardLinks: nil
            )
            #endif
        }
    }

    #if DEBUG
    private static func diagnosticDetail(
        for probe: ProbeResult,
        requiresFileSystemInfo: Bool
    ) -> String {
        var fields = [
            "supports_hard_links=\(probe.supportsHardLinks.map(String.init) ?? "unknown")",
            "fallback_lstat=\(requiresFileSystemInfo)"
        ]
        if let volumeRootPath = probe.volumeRootPath {
            fields.append("volume=\(volumeRootPath)")
        }
        if let errorDescription = probe.errorDescription {
            fields.append("error=\(errorDescription)")
        }
        return fields.joined(separator: " ")
    }
    #endif

    private static func path(_ path: String, isUnder rootPath: String) -> Bool {
        guard rootPath != "/" else {
            return path.hasPrefix("/")
        }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func standardizedPath(for url: URL) -> String {
        normalizedRootPath(url.standardizedFileURL.path)
    }

    private static func normalizedRootPath(_ path: String) -> String {
        var normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return normalizedPath
    }

    private static func cacheRootPath(for probe: ProbeResult, path: String) -> String? {
        if let volumeRootPath = probe.volumeRootPath {
            return normalizedRootPath(volumeRootPath)
        }
        return inferredMountedVolumeRootPath(for: path)
    }

    private static func inferredMountedVolumeRootPath(for path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Volumes" {
            return "/Volumes/\(components[1])"
        }
        return nil
    }
}

nonisolated struct ScanMetadataLoader: Sendable {
    typealias FileSystemInfoProvider = @Sendable (
        URL,
        ScanDiagnosticsContext?
    ) -> (identity: FileIdentity?, linkCount: UInt64)

    // Per-child key sets deliberately omit two keys that were measured as
    // hot-path taxes: `.isReadableKey` costs an access(2) per item for a flag
    // that matters only on rare unreadable entries (those surface through
    // enumeration failures anyway), and `.fileResourceIdentifierKey`
    // allocates a Data per file when hard-link identity is only needed for
    // linkCount > 1 — the lstat fallback covers exactly that case and yields
    // the same FileIdentity form the bulk reader produces.
    static let scanResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .linkCountKey
    ]
    // The root is read once per scan, so it keeps `.isReadableKey` for a
    // truthful isSelfAccessible on the root node.
    static let rootResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isReadableKey,
        .linkCountKey,
        .volumeAvailableCapacityKey,
        .volumeTotalCapacityKey
    ]
    static let atomicSummaryResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .linkCountKey
    ]
    static let atomicSummaryResourceKeySet = Set(atomicSummaryResourceKeys)
    static let atomicProbeResourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey
    ]
    static let atomicProbeResourceKeySet = Set(atomicProbeResourceKeys)

    let diagnostics: ScanDiagnosticsContext?
    private let linkCountCapabilityCache: LinkCountCapabilityCache
    private let fileSystemInfoProvider: FileSystemInfoProvider

    init(
        diagnostics: ScanDiagnosticsContext? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache = LinkCountCapabilityCache(),
        fileSystemInfoProvider: @escaping FileSystemInfoProvider = ScanMetadataLoader.defaultFileSystemInfo
    ) {
        self.diagnostics = diagnostics
        self.linkCountCapabilityCache = linkCountCapabilityCache
        self.fileSystemInfoProvider = fileSystemInfoProvider
    }

    func metadata(
        for url: URL,
        includeVolumeDetails: Bool = false,
        captureDirectoryIdentity: Bool = false
    ) throws -> NodeMetadata {
        let keys = includeVolumeDetails ? Self.rootResourceKeys : Self.scanResourceKeys
        ScanSyscallTally.recordMetadataLoad()
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
            #if DEBUG
            diagnostics?.record(operation: "metadata.resource_values", url: url, startedAt: start)
            #endif
        } catch {
            #if DEBUG
            diagnostics?.record(
                operation: "metadata.resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            #endif
            throw error
        }
        return metadata(
            for: url,
            prefetchedResourceValues: values,
            includeVolumeDetails: includeVolumeDetails,
            captureDirectoryIdentity: captureDirectoryIdentity
        )
    }

    func atomicSummaryMetadata(for url: URL) throws -> NodeMetadata {
        ScanSyscallTally.recordMetadataLoad()
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.atomicSummaryResourceKeySet)
            #if DEBUG
            diagnostics?.record(operation: "metadata.atomic_resource_values", url: url, startedAt: start)
            #endif
        } catch {
            #if DEBUG
            diagnostics?.record(
                operation: "metadata.atomic_resource_values.error",
                url: url,
                startedAt: start,
                detail: "error=\(ScanWarningFactory.diagnosticErrorDescription(error))"
            )
            #endif
            throw error
        }
        return metadata(for: url, prefetchedResourceValues: values)
    }

    nonisolated func metadata(
        for url: URL,
        prefetchedResourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        captureDirectoryIdentity: Bool = false
    ) -> NodeMetadata {
        Self.nodeMetadata(
            for: url,
            resourceValues: values,
            includeVolumeDetails: includeVolumeDetails,
            captureDirectoryIdentity: captureDirectoryIdentity,
            diagnostics: diagnostics,
            linkCountCapabilityCache: linkCountCapabilityCache,
            fileSystemInfoProvider: fileSystemInfoProvider
        )
    }

    private nonisolated static func nodeMetadata(
        for url: URL,
        resourceValues values: URLResourceValues,
        includeVolumeDetails: Bool = false,
        captureDirectoryIdentity: Bool = false,
        diagnostics: ScanDiagnosticsContext? = nil,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        fileSystemInfoProvider: FileSystemInfoProvider
    ) -> NodeMetadata {
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        // Clamp at the source: a buggy filesystem reporting negative sizes
        // must not poison directory totals (or trap conversions) upstream.
        let logicalSize = Int64(max(values.fileSize ?? 0, 0))
        let allocatedSize = Int64(max(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0, 0))
        // Optimistic default: per-child key sets no longer fetch
        // `.isReadableKey`, and unreadable items reveal themselves through
        // enumeration failures. The root keys still fetch it explicitly.
        let isReadable = values.isReadable ?? true
        var fileIdentity = Self.fileIdentity(from: values.fileResourceIdentifier)
        var linkCount = values.linkCount.map { UInt64(max($0, 1)) } ?? 1
        if isSymbolicLink {
            let fileSystemInfo = fileSystemInfoProvider(url, diagnostics)
            fileIdentity = fileSystemInfo.identity
            linkCount = fileSystemInfo.linkCount
        } else if shouldReadFileSystemIdentity(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            url: url,
            fileIdentity: fileIdentity,
            linkCount: values.linkCount,
            linkCountCapabilityCache: linkCountCapabilityCache,
            diagnostics: diagnostics
        ) {
            let fileSystemInfo = fileSystemInfoProvider(url, diagnostics)
            fileIdentity = fileIdentity ?? fileSystemInfo.identity
            linkCount = values.linkCount.map(UInt64.init) ?? fileSystemInfo.linkCount
        } else if captureDirectoryIdentity, isDirectory, fileIdentity == nil {
            // Scan roots ask for directory identity so a rescanned subtree's
            // root matches the identity the bulk reader records when the same
            // directory is enumerated as a child, and so the incremental
            // replaced-root check has something to compare. lstat yields the
            // same device+inode FileIdentity form as the bulk path.
            fileIdentity = fileSystemInfoProvider(url, diagnostics).identity
        }
        let volumeUsedCapacity: Int64?
        if includeVolumeDetails,
           let totalCapacity = values.volumeTotalCapacity,
           let availableCapacity = values.volumeAvailableCapacity {
            volumeUsedCapacity = Int64(max(totalCapacity - availableCapacity, 0))
        } else {
            volumeUsedCapacity = nil
        }

        return NodeMetadata(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            lastModified: values.contentModificationDate,
            isReadable: isReadable,
            volumeUsedCapacity: volumeUsedCapacity,
            fileIdentity: fileIdentity,
            linkCount: linkCount
        )
    }

    private nonisolated static func shouldReadFileSystemIdentity(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        url: URL,
        fileIdentity: FileIdentity?,
        linkCount: Int?,
        linkCountCapabilityCache: LinkCountCapabilityCache,
        diagnostics: ScanDiagnosticsContext?
    ) -> Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        guard let linkCount else {
            return linkCountCapabilityCache.requiresFileSystemInfoWhenLinkCountMissing(
                for: url,
                diagnostics: diagnostics
            )
        }
        return linkCount > 1 && fileIdentity == nil
    }

    private nonisolated static func defaultFileSystemInfo(
        for url: URL,
        diagnostics: ScanDiagnosticsContext? = nil
    ) -> (identity: FileIdentity?, linkCount: UInt64) {
        var fileStat = stat()
        #if DEBUG
        let start = diagnostics?.start()
        #endif
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &fileStat))
        }
        #if DEBUG
        diagnostics?.record(operation: "metadata.lstat", url: url, startedAt: start)
        #endif
        guard result == 0 else {
            return (nil, 1)
        }

        return (
            // bitPattern: dev_t is signed and virtual/network filesystems
            // can report negative device numbers; UInt64(_:) would trap.
            FileIdentity(
                device: UInt64(bitPattern: Int64(fileStat.st_dev)),
                inode: UInt64(fileStat.st_ino)
            ),
            max(UInt64(fileStat.st_nlink), 1)
        )
    }

    private nonisolated static func fileIdentity(
        from resourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> FileIdentity? {
        guard let identifierData = resourceIdentifier as? Data else { return nil }
        return FileIdentity(resourceIdentifier: identifierData)
    }
}

nonisolated struct NodeMetadata: Sendable {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let lastModified: Date?
    let isReadable: Bool
    let volumeUsedCapacity: Int64?
    let fileIdentity: FileIdentity?
    let linkCount: UInt64
    /// Cloud file whose content is not downloaded (SF_DATALESS). Detected on
    /// the getattrlistbulk path; the URLResourceValues fallback reports false
    /// (no key exposes it, and cloud volumes are APFS so they take the bulk
    /// path anyway).
    var isDataless: Bool = false
    /// APFS clone-family membership (refCount > 1 only). Captured on the
    /// getattrlistbulk path; the URLResourceValues fallback has no clone
    /// keys, and non-APFS volumes have no clones to report.
    var cloneInfo: CloneInfo? = nil
}

/// BSD st_flags bits the scanner cares about (sys/stat.h).
nonisolated enum BSDFileFlags {
    /// SF_DATALESS: file content lives in a cloud drive, not on disk.
    static let dataless: UInt32 = 0x4000_0000
}

public nonisolated enum FileIdentity: Hashable, Sendable {
    case resourceIdentifier(Data)
    case fileSystem(device: UInt64, inode: UInt64)

    nonisolated init(device: UInt64, inode: UInt64) {
        self = .fileSystem(device: device, inode: inode)
    }

    nonisolated init(resourceIdentifier: Data) {
        self = .resourceIdentifier(resourceIdentifier)
    }

    nonisolated var isFileSystemIdentity: Bool {
        if case .fileSystem = self {
            return true
        }
        return false
    }

    nonisolated var fileSystemDeviceID: UInt64? {
        guard case .fileSystem(let device, _) = self else { return nil }
        return device
    }
}
