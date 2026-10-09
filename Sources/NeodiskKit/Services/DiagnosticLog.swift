//
//  DiagnosticLog.swift
//  Neodisk
//

import Foundation
#if canImport(os)
import os
#endif

/// Neodisk's log: stderr, the unified log (subsystem = bundle id) and, after `persist(to:)`,
/// a rolling file that outlives a crash. Log events, never per-entry work.
public nonisolated struct DiagnosticLog: Sendable {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, notice, warning, error, fault

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .warning: "warning"
            case .error: "error"
            case .fault: "fault"
            }
        }
    }

    public static let scan = DiagnosticLog("scan")
    public static let cache = DiagnosticLog("cache")
    public static let rescan = DiagnosticLog("rescan")
    public static let app = DiagnosticLog("app")
    public static let memory = DiagnosticLog("memory")
    public static let performance = DiagnosticLog("performance")
    public static let cloud = DiagnosticLog("cloud")

    public let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(_ category: String) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: AppChannel.current.identifier, category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(.notice, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }
    public func fault(_ message: @autoclosure () -> String) { log(.fault, message()) }

    public func log(_ level: Level, _ message: String) {
        #if canImport(os)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
        #endif
        guard level >= .info else { return }
        let line = "\(Self.timestamp()) \(level.label) [\(category)] \(message)\n"
        if Self.mirrorsToStandardError {
            FileHandle.standardError.write(Data(line.utf8))
        }
        DiagnosticLogFile.shared.append(line, synchronously: level >= .error)
    }

    /// Writes info and above to `<name>.log`, rotated once at `maxBytes`. Only the apps call it.
    public static func persist(to directory: URL, name: String = "neodisk", maxBytes: Int = 2_000_000) {
        DiagnosticLogFile.shared.open(directory: directory, name: name, maxBytes: maxBytes)
    }

    /// The log and its rotated predecessor, oldest first.
    public static var files: [URL] { DiagnosticLogFile.shared.files }

    /// `~/Library/Logs/<app>` on macOS, `$XDG_STATE_HOME/<slug>` elsewhere; `NEODISK_LOG_DIR` overrides.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NEODISK_LOG_DIR"] {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appending(path: "Library/Logs/\(AppChannel.current.appName)", directoryHint: .isDirectory)
        #else
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(filePath: $0) }
            ?? home.appending(path: ".local/state", directoryHint: .isDirectory)
        return state.appending(path: AppChannel.current.slug, directoryHint: .isDirectory)
        #endif
    }

    /// Off in the release app (stderr goes nowhere) unless a dev hook asks.
    private static let mirrorsToStandardError: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["NEODISK_LOG_STDERR"] == "0" { return false }
        return Bundle.main.bundleIdentifier == nil || isatty(STDERR_FILENO) != 0
            || environment["NEODISK_LOG_STDERR"] == "1" || ScanTiming.isEnabled
    }()

    /// Local time with its UTC offset, `2026-10-09T08:07:09.699-07:00`.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    private static func timestamp() -> String {
        Date.now.formatted(timestampStyle)
    }
}

/// One serial queue; errors and faults write synchronously so the line before a crash lands.
private nonisolated final class DiagnosticLogFile: @unchecked Sendable {
    static let shared = DiagnosticLogFile()

    private let queue = DispatchQueue(label: "Neodisk.DiagnosticLog", qos: .utility)
    // Guarded by `queue`.
    private var handle: FileHandle?
    private var url: URL?
    private var size = 0
    private var maxBytes = 0

    func open(directory: URL, name: String, maxBytes: Int) {
        queue.sync {
            try? handle?.close()
            handle = nil
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: "\(name).log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                size = Int(try handle.seekToEnd())
                self.handle = handle
                self.url = url
                self.maxBytes = maxBytes
            } catch {
                FileHandle.standardError.write(Data("Neodisk: cannot open log in \(directory.path): \(error)\n".utf8))
            }
        }
    }

    var files: [URL] {
        queue.sync {
            guard let url else { return [] }
            return [rotatedURL(url), url].filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    func append(_ line: String, synchronously: Bool) {
        let work: @Sendable () -> Void = { [self] in
            guard let handle else { return }
            let data = Data(line.utf8)
            handle.write(data)
            size += data.count
            if size > maxBytes { rotate() }
        }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    private func rotate() {
        guard let url else { return }
        try? handle?.close()
        handle = nil
        let previous = rotatedURL(url)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        size = 0
    }

    private func rotatedURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".1")
    }
}
