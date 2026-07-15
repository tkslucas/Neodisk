//
//  SystemIntegration.swift
//  Neodisk
//

import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import NeodiskKit

enum FullDiskAccessStatus: Equatable, Sendable {
    case granted
    case notGranted
    case unknown
}

protocol SystemWorkspace {
    func activateFileViewerSelecting(_ fileURLs: [URL])
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: SystemWorkspace {}

protocol PathPasteboard {
    @discardableResult
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PathPasteboard {}

enum SystemIntegration {
    typealias FullDiskAccessProbe = () throws -> Void
    private nonisolated static let requiredReadableDataVaultProbeCount = 2
    private nonisolated static let requiredReadableMacOS27SentinelCount = 2
    private nonisolated static let macOS27MajorVersion = 27

    enum SystemIntegrationError: LocalizedError {
        case openFailed(path: String)
        case copyPathFailed(path: String)
        case quickLookUnavailable(path: String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path):
                return String(format: NSLocalizedString("macOS could not open the item at %@.", comment: "Open failure"), path)
            case .copyPathFailed(let path):
                return String(format: NSLocalizedString("macOS could not copy the path for %@.", comment: "Copy path failure"), path)
            case .quickLookUnavailable(let path):
                return String(format: NSLocalizedString("The item at %@ is no longer available for Quick Look.", comment: "Quick Look unavailable"), path)
            }
        }
    }

    private static var isRunningInsideXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    @MainActor
    static func presentScanPanel() -> ScanTarget? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = NSLocalizedString("Scan", comment: "Open panel confirm button")
        panel.message = NSLocalizedString("Choose a folder or mounted volume to analyze.", comment: "Open panel message")

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return ScanTarget(url: url)
    }

    /// Mounted volumes for the sidebar's Volumes section: the startup disk
    /// first, then every other visible mounted volume. Never removable.
    nonisolated static func volumeTargets() -> [ScanTarget] {
        let startupDisk = ScanTarget(url: URL(filePath: "/", directoryHint: .isDirectory), kind: .volume)
        var targets = [startupDisk]

        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in mountedVolumes where volume.path != "/" {
            targets.append(ScanTarget(url: volume, kind: .volume))
        }

        return deduplicate(targets)
    }

    /// The common folders the sidebar's Folders section is seeded with on
    /// first launch. After seeding they are ordinary sidebar folders — the
    /// user can remove any of them (unlike volumes and cloud locations).
    nonisolated static func defaultFolderTargets() -> [ScanTarget] {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser

        var targets = [ScanTarget(url: homeDirectory, kind: .folder)]
        let commonFolders = ["Desktop", "Documents", "Downloads", "Library"]
            .map { homeDirectory.appending(path: $0, directoryHint: .isDirectory) }
            + [URL(filePath: "/Applications", directoryHint: .isDirectory)]
        for url in commonFolders where fileManager.fileExists(atPath: url.path) {
            targets.append(ScanTarget(url: url, kind: .folder))
        }

        return deduplicate(targets)
    }

    /// Locally-synced cloud storage folders, shown in the sidebar's own
    /// "Local Cloud Files" section. Deduplicated because a legacy ~/Dropbox
    /// symlink resolves to the same File Provider folder it points into.
    nonisolated static func cloudTargets(fileManager: FileManager = .default) -> [ScanTarget] {
        deduplicate(CloudLocationDetector.detectedTargets(fileManager: fileManager))
    }

    nonisolated static func targetCapacityDescriptions() -> [String: String] {
        let fileManager = FileManager.default
        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? [URL(filePath: "/", directoryHint: .isDirectory)]

        return targetCapacityDescriptions(
            mountedVolumes: mountedVolumes,
            capacityDescriptionForURL: capacityDescription(for:)
        )
    }

    nonisolated static func targetCapacityDescriptions(
        mountedVolumes: [URL],
        capacityDescriptionForURL: (URL) -> String?
    ) -> [String: String] {
        var descriptions: [String: String] = [:]
        descriptions.reserveCapacity(mountedVolumes.count)

        for volumeURL in mountedVolumes {
            guard let description = capacityDescriptionForURL(volumeURL) else { continue }
            descriptions[volumeURL.standardizedFileURL.path] = description
        }

        return descriptions
    }

    static func reveal(_ url: URL, workspace: SystemWorkspace = NSWorkspace.shared) {
        reveal([url], workspace: workspace)
    }

    static func reveal(_ urls: [URL], workspace: SystemWorkspace = NSWorkspace.shared) {
        workspace.activateFileViewerSelecting(urls)
    }

    static func open(_ url: URL, workspace: SystemWorkspace = NSWorkspace.shared) throws {
        guard workspace.open(url) else {
            throw SystemIntegrationError.openFailed(path: url.path)
        }
    }

    static func copyPath(_ url: URL, pasteboard: PathPasteboard = NSPasteboard.general) throws {
        pasteboard.clearContents()
        let copiedPath = pasteboard.setString(url.path, forType: .string)
        let copiedURL = pasteboard.setString(url.absoluteString, forType: .fileURL)

        guard copiedPath && copiedURL else {
            throw SystemIntegrationError.copyPathFailed(path: url.path)
        }
    }

    static func copyPaths(_ urls: [URL], pasteboard: PathPasteboard = NSPasteboard.general) throws {
        guard let firstURL = urls.first else { return }
        guard urls.count > 1 else {
            try copyPath(firstURL, pasteboard: pasteboard)
            return
        }

        pasteboard.clearContents()
        let paths = urls.map(\.path).joined(separator: "\n")

        guard pasteboard.setString(paths, forType: .string) else {
            throw SystemIntegrationError.copyPathFailed(path: firstURL.path)
        }
    }

    @discardableResult
    static func openFullDiskAccessSettings() -> Bool {
        guard !isRunningInsideXcodePreview else {
            return false
        }

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func prepareAndOpenFullDiskAccessSettings() -> Bool {
        guard !isRunningInsideXcodePreview else {
            return false
        }

        primeFullDiskAccessListEntry()
        return openFullDiskAccessSettings()
    }

    static func primeFullDiskAccessListEntry() {
        _ = fullDiskAccessStatus()
    }

    nonisolated static func fullDiskAccessStatus() -> FullDiskAccessStatus {
        let macOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return fullDiskAccessStatus(
            macOSMajorVersion: macOSMajorVersion,
            probes: resolvedProbes(
                for: macOSMajorVersion < macOS27MajorVersion ? legacySentinels : macOS27Sentinels
            )
        )
    }

    /// One sentinel path whose readability is evidence about Full Disk
    /// Access — the probe list is data; only the two per-generation verdict
    /// rules below are code.
    private struct FullDiskAccessSentinel {
        enum Location {
            case system(String)
            case home(String)
        }

        enum Role {
            /// Load-bearing: decides the verdict (see the rules below).
            case gatekeeper
            /// Counts only toward the fallback quorum.
            case evidence
        }

        let location: Location
        let kind: ProtectedPathProbe.Kind
        let role: Role
    }

    /// Pre-27: the user TCC database is the gatekeeper, classic data vaults
    /// are the quorum evidence.
    private nonisolated static let legacySentinels: [FullDiskAccessSentinel] = [
        .init(location: .home("Library/Application Support/com.apple.TCC/TCC.db"), kind: .file, role: .gatekeeper),
        .init(location: .home("Library/Mail"), kind: .directory, role: .evidence),
        .init(location: .home("Library/Messages"), kind: .directory, role: .evidence),
        .init(location: .home("Library/Safari"), kind: .directory, role: .evidence),
        .init(location: .home("Library/HomeKit"), kind: .directory, role: .evidence),
    ]

    /// macOS 27 re-protected the classic sentinels; these two gatekeepers
    /// decide together when both exist, with the system TCC database as
    /// fallback evidence only.
    private nonisolated static let macOS27Sentinels: [FullDiskAccessSentinel] = [
        .init(location: .system("/Library/Preferences/com.apple.TimeMachine.plist"), kind: .file, role: .gatekeeper),
        .init(location: .home("Library/Containers/com.apple.stocks"), kind: .directory, role: .gatekeeper),
        .init(location: .system("/Library/Application Support/com.apple.TCC/TCC.db"), kind: .file, role: .evidence),
    ]

    /// Resolved probes for a sentinel list; nil means the sentinel path does
    /// not exist on this system.
    struct FullDiskAccessProbeSet {
        var gatekeepers: [FullDiskAccessProbe?]
        var evidence: [FullDiskAccessProbe?]
    }

    private nonisolated static func resolvedProbes(
        for sentinels: [FullDiskAccessSentinel]
    ) -> FullDiskAccessProbeSet {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        var probes = FullDiskAccessProbeSet(gatekeepers: [], evidence: [])

        for sentinel in sentinels {
            let url: URL
            switch sentinel.location {
            case .system(let path):
                url = URL(filePath: path)
            case .home(let path):
                url = homeDirectory.appending(
                    path: path,
                    directoryHint: sentinel.kind == .directory ? .isDirectory : .notDirectory
                )
            }
            let probe = makeFullDiskAccessProbe(
                for: ProtectedPathProbe(url: url, kind: sentinel.kind),
                using: fileManager
            )
            switch sentinel.role {
            case .gatekeeper:
                probes.gatekeepers.append(probe)
            case .evidence:
                probes.evidence.append(probe)
            }
        }

        return probes
    }

    nonisolated static func fullDiskAccessStatus(
        macOSMajorVersion: Int,
        probes: FullDiskAccessProbeSet
    ) -> FullDiskAccessStatus {
        macOSMajorVersion < macOS27MajorVersion
            ? legacyFullDiskAccessStatus(probes)
            : macOS27FullDiskAccessStatus(probes)
    }

    /// Granted needs every gatekeeper readable plus a quorum of readable
    /// evidence vaults; no sentinel existing at all means the heuristic has
    /// nothing to say.
    private nonisolated static func legacyFullDiskAccessStatus(
        _ probes: FullDiskAccessProbeSet
    ) -> FullDiskAccessStatus {
        let existingEvidence = probes.evidence.compactMap { $0 }
        let foundProtectedCandidate = probes.gatekeepers.contains { $0 != nil } || !existingEvidence.isEmpty
        guard foundProtectedCandidate else { return .unknown }
        guard probes.gatekeepers.allSatisfy({ $0.map(canReadFullDiskAccessProbe) == true }) else {
            return .notGranted
        }

        let readableCount = existingEvidence.filter(canReadFullDiskAccessProbe).count
        return readableCount >= requiredReadableDataVaultProbeCount ? .granted : .notGranted
    }

    /// The gatekeepers decide alone when all of them exist; otherwise fall
    /// back to a quorum over everything that does, defaulting to unknown —
    /// the macOS 27 sentinels are too new to trust a hard negative.
    private nonisolated static func macOS27FullDiskAccessStatus(
        _ probes: FullDiskAccessProbeSet
    ) -> FullDiskAccessStatus {
        if probes.gatekeepers.allSatisfy({ $0 != nil }) {
            let allReadable = probes.gatekeepers.allSatisfy {
                $0.map(canReadFullDiskAccessProbe) == true
            }
            return allReadable ? .granted : .notGranted
        }

        let readableCount = (probes.gatekeepers + probes.evidence)
            .compactMap { $0 }
            .filter(canReadFullDiskAccessProbe)
            .count
        return readableCount >= requiredReadableMacOS27SentinelCount ? .granted : .unknown
    }

    private nonisolated static func makeFullDiskAccessProbe(
        for candidate: ProtectedPathProbe,
        using fileManager: FileManager
    ) -> FullDiskAccessProbe? {
        guard fileManager.fileExists(atPath: candidate.url.path) else { return nil }
        return {
            try candidate.probe(using: fileManager)
        }
    }

    private nonisolated static func canReadFullDiskAccessProbe(_ probe: FullDiskAccessProbe) -> Bool {
        do {
            try probe()
            return true
        } catch {
            return false
        }
    }

    nonisolated static func deduplicate(_ targets: [ScanTarget]) -> [ScanTarget] {
        var seen = Set<String>()
        return targets.filter { target in
            seen.insert(target.id).inserted
        }
    }

    private nonisolated static func capacityDescription(for url: URL) -> String? {
        guard let info = VolumeSpaceInfo.load(for: url) else { return nil }
        return capacityDescription(info: info)
    }

    /// "X free of Y" with the Finder-style available figure: free plus
    /// purgeable, matching what Finder and Disk Utility call available.
    nonisolated static func capacityDescription(info: VolumeSpaceInfo) -> String? {
        let totalText = NeodiskFormatters.size(info.totalCapacity)
        let availableText = NeodiskFormatters.size(info.availableCapacity)
        return "\(availableText) free of \(totalText)"
    }
}

private struct ProtectedPathProbe {
    enum Kind {
        case directory
        case file
    }

    var url: URL
    var kind: Kind

    nonisolated func probe(using fileManager: FileManager) throws {
        switch kind {
        case .directory:
            _ = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
        case .file:
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
        }
    }
}

enum PermissionAdvisor {
    // Fragments whose contents Full Disk Access actually unlocks. Note that the
    // TCC directory itself (/Library/Application Support/com.apple.TCC) is
    // root-owned/SIP-protected and stays unreadable even with FDA, so it must
    // not be listed here — matching it would suggest FDA for a grant that can
    // never resolve the warning.
    private static let fullDiskAccessProtectedPathFragments = [
        "/Library/Mail",
        "/Library/Messages",
        "/Library/Safari",
        "/Library/HomeKit",
    ]

    static func shouldSuggestFullDiskAccess(
        for snapshot: ScanSnapshot?,
        fullDiskAccessStatus: FullDiskAccessStatus
    ) -> Bool {
        // Don't nag for access that is already granted. Many system paths
        // (e.g. /Library/Caches/com.apple.iconservices.store) stay unreadable
        // regardless of FDA, so warning presence alone must not drive the prompt.
        guard fullDiskAccessStatus != .granted else { return false }
        guard let snapshot else { return false }
        return snapshot.scanWarnings.contains(where: { warning in
            warning.category == .permissionDenied &&
                fullDiskAccessProtectedPathFragments.contains(where: { warning.path.contains($0) })
        })
    }
}
