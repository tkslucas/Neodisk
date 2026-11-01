// Without Full Disk Access, the first read of a privacy-protected folder blocks until the user answers a macOS
// prompt. A read there that outlasts `threshold` is reported, so the window can say what the scan waits on.

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

    /// Home folders macOS asks about before their first read (Pictures holds the Photos library).
    static let protectedHomeFolders = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures",
        "Library/Mobile Documents", "Library/Containers", "Library/Group Containers",
    ]

    private let roots: [String]
    /// The home folders the roots sit in: most paths of a volume scan fail this first, cheap test.
    private let homes: [String]
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
        roots = Self.roots(scanRoot: scanRoot, home: configuration.home)
        guard !roots.isEmpty else { return nil }
        homes = Array(Set(roots.map { ($0 as NSString).deletingLastPathComponent }))
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
        return !roots(scanRoot: scanRoot, home: home).isEmpty
    }

    private static func roots(scanRoot: String, home: String) -> [String] {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        // Volume scans may reach home through the Data volume's own path.
        let candidates = [home, "/System/Volumes/Data" + home].flatMap { home in
            protectedHomeFolders.map { home + "/" + $0 }
        }
        let scanRoot = scanRoot == "/" ? "" : scanRoot
        return candidates.filter { path($0, isWithin: scanRoot) || path(scanRoot, isWithin: $0) }
    }

    /// Marks a read of `path` in flight; nil (nothing to watch) outside the protected folders.
    func begin(_ path: String) -> Int? {
        guard homes.contains(where: { path.hasPrefix($0) }),
              let root = roots.first(where: { Self.path(path, isWithin: $0) }) else { return nil }
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
        let descriptor = open(path, O_RDONLY | O_DIRECTORY)
        if descriptor >= 0 { close(descriptor) }
    }

    private static func path(_ path: String, isWithin root: String) -> Bool {
        path == root || root.isEmpty || path.hasPrefix(root + "/")
    }
}
