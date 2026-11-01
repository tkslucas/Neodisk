// The file-table indexes of volumes being scanned right now. While a scan holds one, every directory read under
// that volume (traversal, auto-summary probes) is answered from memory with the same records the disk reader
// would produce, so the rest of the engine runs unchanged.

import Foundation

nonisolated enum NTFSIndexRegistry {
    private struct Registration {
        let id: Int
        /// `URL.path` form with a trailing slash: `C:/`, or a mounted folder's path.
        let rootPrefix: String
        let foldedPrefix: String
        let index: NTFSVolumeIndex
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registrations: [Registration] = []
    nonisolated(unsafe) private static var nextID = 0

    /// `rootPath` is the volume's root in `URL.path` form (`C:/`).
    static func register(_ index: NTFSVolumeIndex, rootPath: String) -> Int {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        registrations.append(Registration(id: nextID, rootPrefix: prefix, foldedPrefix: prefix.lowercased(), index: index))
        return nextID
    }

    static func unregister(_ id: Int) {
        lock.lock()
        registrations.removeAll { $0.id == id }
        lock.unlock()
    }

    static var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registrations.isEmpty
    }

    /// The registered index and record for a directory, or nil when no index covers it or the index doesn't
    /// know it (created after the file table was read): the caller then reads the disk.
    static func directory(atPath path: String) -> (index: NTFSVolumeIndex, record: UInt32)? {
        lock.lock()
        let registrations = self.registrations
        lock.unlock()
        guard !registrations.isEmpty else { return nil }

        let directoryPath = path.hasSuffix("/") ? path : path + "/"
        var best: Registration?
        for registration in registrations {
            // Windows paths compare without case; only the volume part is compared here, names resolve below.
            let covers = directoryPath.prefix(registration.rootPrefix.count).lowercased() == registration.foldedPrefix
            if covers, registration.rootPrefix.count > (best?.rootPrefix.count ?? -1) {
                best = registration
            }
        }
        guard let best else { return nil }
        let components = directoryPath.dropFirst(best.rootPrefix.count).split(separator: "/").map(String.init)
        guard let record = best.index.resolve(components: components),
              best.index.isInUseDirectory(record) else {
            return nil
        }
        return (best.index, record)
    }
}
