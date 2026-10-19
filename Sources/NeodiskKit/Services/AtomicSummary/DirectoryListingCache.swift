import Foundation

/// Listings the summary probe already read, so the summary walk doesn't list them again (a big cache folder
/// was listed twice). Scoped to one scan; each is taken once, and an entry budget bounds untaken ones.
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
