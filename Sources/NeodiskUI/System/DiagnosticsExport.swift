//
//  DiagnosticsExport.swift
//  Neodisk
//

import AppKit
import NeodiskAppModel
import NeodiskKit
import UniformTypeIdentifiers

/// Help ▸ Export Diagnostics…: zips the log, MetricKit and crash reports with a system
/// summary to where the user picks. Nothing leaves the Mac otherwise.
@MainActor
enum DiagnosticsExport {
    static func run() {
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppChannel.current.appName) Diagnostics \(stamp).zip"
        panel.allowedContentTypes = [.zip]
        panel.message = String(localized: "The diagnostics include folder paths from your scans. Review them before sharing.")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try export(to: destination)
            DiagnosticLog.app.notice("exported diagnostics")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            DiagnosticLog.app.error("diagnostics export failed: \(error)")
            NSAlert(error: error).runModal()
        }
    }

    static func export(to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folder = staging.appending(path: destination.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try summary().write(to: folder.appending(path: "system.txt"), atomically: true, encoding: .utf8)
        let groups: [(String, [URL])] = [
            ("", DiagnosticLog.files),
            ("MetricKit", DiagnosticsMonitor.metricKitPayloads),
            ("CrashReports", DiagnosticsMonitor.crashReports(since: .now.addingTimeInterval(-30 * 86_400)))
        ]
        for (subfolder, files) in groups where !files.isEmpty {
            let target = subfolder.isEmpty ? folder : folder.appending(path: subfolder, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files {
                try fileManager.copyItem(at: file, to: target.appending(path: file.lastPathComponent))
            }
        }

        // Coordinated reading "for uploading" hands back a zip of a folder.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zip, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    private static func summary() -> String {
        let process = ProcessInfo.processInfo
        return """
        \(AppChannel.current.appName) \(AppVersion.display)
        macOS \(process.operatingSystemVersionString)
        \(SystemInfo.model), \(process.activeProcessorCount) cores, \
        \(MemoryFootprint.megabytes(process.physicalMemory) / 1024) GB RAM
        Now: \(MemoryFootprint.summary())
        Exported: \(Date.now.formatted(.iso8601))

        """
    }
}
