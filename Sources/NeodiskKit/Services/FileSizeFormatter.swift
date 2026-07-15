//
//  FileSizeFormatter.swift
//  Neodisk
//

import Foundation

/// Formatting the core and CLI actually need: byte counts and percentages.
/// Display-only formatting (dates, durations) lives in the app
/// (DisplayFormatters).
public enum NeodiskFormatters {
    /// Signed size delta for diff displays: "+1.2 GB", "−340 MB", or a
    /// quiet "·" for unchanged. The outline's width-measurement path and the
    /// rendered DeltaLabel must produce byte-identical strings, so both
    /// call this.
    public static func sizeDelta(_ delta: Int64) -> String {
        if delta == 0 { return "·" }
        if delta > 0 { return "+\(size(delta))" }
        return "−\(size(-delta))"
    }

    private static let formatterCache = FormatterCache()

    public static func size(_ bytes: Int64) -> String {
        formatterCache.size(bytes)
    }

    public static func percentage(part: Int64, total: Int64) -> String? {
        guard total > 0 else { return nil }
        return (Double(part) / Double(total))
            .formatted(.percent.precision(.fractionLength(1)))
    }
}

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let byteFormatter: ByteCountFormatter

    init() {
        let byteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        byteFormatter.countStyle = .file
        byteFormatter.includesActualByteCount = false
        byteFormatter.isAdaptive = true
        self.byteFormatter = byteFormatter
    }

    func size(_ bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return byteFormatter.string(fromByteCount: bytes)
    }
}
