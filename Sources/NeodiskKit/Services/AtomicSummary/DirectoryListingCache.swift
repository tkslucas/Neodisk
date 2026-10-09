import Foundation

/// Full directory listings the auto-summary probe has already read, handed
/// to the summary walk that follows so it doesn't read them again. A probe
/// that leads to a summary reads the same folders the summary then walks;
/// without this a big cache folder was listed twice (and its parent three
/// times). Scoped to one scan's summary pool, so nothing outlives the scan.
/// Each listing is taken once; the entry budget bounds memory when probes
/// decline and their listings are never taken.
nonisolated final class DirectoryListingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: [BulkDirectoryChild]] = [:]
    private var entryCount = 0
    private let maximumEntryCount: Int

    init(maximumEntryCount: Int = 250_000) {
        self.maximumEntryCount = maximumEntryCount
    }

    func store(_ children: [BulkDirectoryChild], forDirectory path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard entryCount + children.count <= maximumEntryCount, listings[path] == nil else { return }
        listings[path] = children
        entryCount += children.count
    }

    func take(forDirectory path: String) -> [BulkDirectoryChild]? {
        lock.lock()
        defer { lock.unlock() }
        guard let children = listings.removeValue(forKey: path) else { return nil }
        entryCount -= children.count
        return children
    }
}
