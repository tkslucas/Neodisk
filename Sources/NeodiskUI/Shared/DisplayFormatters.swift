//
//  DisplayFormatters.swift
//  Neodisk
//
//  Display-only formatting (dates, rough durations) — moved up from
//  NeodiskKit, which keeps only what the core and CLI consume.
//

import Foundation

enum DisplayFormatters {
    private static let formatterCache = FormatterCache()

    /// "3 minutes ago", "yesterday" — for last-scan labels. Views driven by
    /// a TimelineView pass the timeline date as `relativeTo` so the string
    /// is a pure function of its inputs and re-renders on schedule.
    static func relativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        formatterCache.relativeDate(date, relativeTo: now)
    }

    /// "45 seconds", "3 minutes", "2 hours" — a rough single-unit duration,
    /// for "the last scan took about …" labels.
    static func roughDuration(_ interval: TimeInterval) -> String {
        formatterCache.roughDuration(interval)
    }

    /// User-facing form of a node path. Filesystem paths pass through; cloud
    /// node paths ("cloudscan://<provider>/<account>/My Drive/…") drop the
    /// machine-oriented prefix and read from the drive root ("/My Drive/…"),
    /// matching how the rest of the row already shows the account by name.
    static func displayPath(_ path: String) -> String {
        let cloudPrefix = "cloudscan://"
        guard path.hasPrefix(cloudPrefix) else { return path }
        // Skip "<provider>/<account>" after the scheme.
        var remainder = path.dropFirst(cloudPrefix.count)
        for _ in 0..<2 {
            guard let slash = remainder.firstIndex(of: "/") else { return "/" }
            remainder = remainder[remainder.index(after: slash)...]
        }
        return "/" + remainder
    }
}

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let relativeDateFormatter: RelativeDateTimeFormatter
    private let durationFormatter: DateComponentsFormatter

    init() {
        let durationFormatter = DateComponentsFormatter()
        durationFormatter.allowedUnits = [.hour, .minute, .second]
        durationFormatter.unitsStyle = .full
        durationFormatter.maximumUnitCount = 1
        self.durationFormatter = durationFormatter

        let relativeDateFormatter = RelativeDateTimeFormatter()
        relativeDateFormatter.dateTimeStyle = .named
        self.relativeDateFormatter = relativeDateFormatter
    }

    func relativeDate(_ date: Date, relativeTo now: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        // Sub-minute ages read as "in 0 seconds" quirks; pin them.
        if abs(date.timeIntervalSince(now)) < 60 {
            return NSLocalizedString("just now", comment: "Relative time for a very recent scan")
        }
        return relativeDateFormatter.localizedString(for: date, relativeTo: now)
    }

    func roughDuration(_ interval: TimeInterval) -> String {
        lock.lock()
        defer { lock.unlock() }
        return durationFormatter.string(from: max(interval, 1)) ?? "\(Int(interval)) seconds"
    }
}
