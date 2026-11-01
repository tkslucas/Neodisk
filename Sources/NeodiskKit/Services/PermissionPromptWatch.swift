// Without Full Disk Access, the first read of a privacy-protected folder blocks until the user answers a macOS
// prompt. Only that first listing is timed; one outlasting `threshold` is reported so the window can say so.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

package nonisolated final class PermissionPromptWatch: @unchecked Sendable {
    struct Configuration: Sendable {
        var home: String
        var threshold: Duration = .seconds(3)

        static var standard: Configuration? {
            #if os(macOS)
            Configuration(home: NSHomeDirectory())
            #else
            nil
            #endif
        }
    }

    /// Home folders macOS asks about before their first read, and the Photos library.
    static let protectedHomeFolders = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures/Photos Library.photoslibrary", "Library/Mobile Documents",
    ]
    /// Each app's folder in these asks on its own ("data from other apps").
    static let containerFolders = ["Library/Containers", "Library/Group Containers"]

    /// A listing that can prompt: the folder itself, or (`perChild`) each direct child of it.
    private struct Unit {
        let bytes: [UInt8]
        let root: String
        let perChild: Bool
    }

    private let units: [Unit]
    /// Every unit starts with one of these, so most paths of a scan fail one byte compare.
    private let homes: [[UInt8]]
    private let threshold: Duration
    private let report: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var reads: [Int: (root: String, start: ContinuousClock.Instant)] = [:]
    private var nextToken = 0
    private var reported: String?
    private var isStopped = false
    private var ticker: Task<Void, Never>?

    /// Nil when no protected folder lies inside the scanned folder or around it.
    init?(scanRoot: String, configuration: Configuration?, report: @escaping @Sendable (String?) -> Void) {
        guard let configuration else { return nil }
        let (units, homes) = Self.units(scanRoot: scanRoot, home: configuration.home)
        guard !units.isEmpty else { return nil }
        self.units = units
        self.homes = homes.map { Array($0.utf8) }
        threshold = configuration.threshold
        self.report = report
        ticker = Task.detached(priority: .utility) { [weak self, threshold] in
            while !Task.isCancelled {
                try? await Task.sleep(for: min(threshold / 2, .milliseconds(500)))
                self?.check()
            }
        }
    }

    deinit {
        ticker?.cancel()
    }

    /// Whether a scan of `scanRoot` can stop at a macOS permission prompt (macOS only).
    package static func reachesProtectedFolder(_ scanRoot: String) -> Bool {
        guard let home = Configuration.standard?.home else { return false }
        return !units(scanRoot: scanRoot, home: home).units.isEmpty
    }

    private static func units(scanRoot: String, home: String) -> (units: [Unit], homes: [String]) {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        // Volume scans may reach home through the Data volume's own path.
        let homes = [home, "/System/Volumes/Data" + home]
        let scanRoot = scanRoot == "/" ? "" : scanRoot
        var units: [Unit] = []
        for home in homes {
            let roots = protectedHomeFolders.map { (home + "/" + $0, false) } + containerFolders.map { (home + "/" + $0, true) }
            for (root, perChild) in roots {
                if path(root, isWithin: scanRoot) {
                    units.append(Unit(bytes: Array((perChild ? root + "/" : root).utf8), root: root, perChild: perChild))
                } else if path(scanRoot, isWithin: root) {
                    // Scanning inside a protected folder: the scan's own first listing is the one that prompts.
                    units.append(Unit(bytes: Array(scanRoot.utf8), root: root, perChild: false))
                }
            }
        }
        return (units, homes.map { $0 + "/" })
    }

    /// Marks the listing of `path` in flight when it's one that can prompt; nil (nothing to time) otherwise.
    func begin(_ path: String) -> Int? {
        guard let root = unitRoot(of: path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        reads[nextToken] = (root, .now)
        return nextToken
    }

    func end(_ token: Int?) {
        guard let token else { return }
        lock.lock()
        reads.removeValue(forKey: token)
        lock.unlock()
        check()
    }

    /// Clears a standing report; nothing is reported afterwards.
    func stop() {
        ticker?.cancel()
        lock.lock()
        defer { lock.unlock() }
        isStopped = true
        if reported != nil {
            reported = nil
            report(nil)
        }
    }

    /// Byte compares on the path's own storage: this runs for every directory a scan lists.
    private func unitRoot(of path: String) -> String? {
        var path = path
        return path.withUTF8 { bytes -> String? in
            guard homes.contains(where: { bytes.starts(with: $0) }) else { return nil }
            for unit in units {
                if unit.perChild {
                    guard bytes.count > unit.bytes.count, bytes.starts(with: unit.bytes),
                          !bytes[unit.bytes.count...].contains(UInt8(ascii: "/")) else { continue }
                    return unit.root
                } else if bytes.count == unit.bytes.count, bytes.elementsEqual(unit.bytes) {
                    return unit.root
                }
            }
            return nil
        }
    }

    /// Reports under the lock, so a late tick can never land after `stop`'s clear.
    private func check() {
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        let waiting = reads.values
            .filter { $0.start.duration(to: now) >= threshold }
            .min { $0.start < $1.start }?.root
        guard waiting != reported else { return }
        reported = waiting
        report(waiting)
    }

    /// Opens a package before it is summarized, so a prompt it raises is timed here, not inside the long summary.
    static func touch(_ path: String) {
        #if os(macOS)
        let descriptor = open(path, O_RDONLY | O_DIRECTORY)
        if descriptor >= 0 { close(descriptor) }
        #endif
    }

    private static func path(_ path: String, isWithin root: String) -> Bool {
        path == root || root.isEmpty || path.hasPrefix(root + "/")
    }
}
