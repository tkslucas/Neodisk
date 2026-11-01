import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

@MainActor
struct TrashPolicyCacheTests {
    private final class Builds: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        var count: Int { lock.withLock { threads.count } }
        var onMain: Int { lock.withLock { threads.filter { $0 }.count } }
        func record() { lock.withLock { threads.append(Thread.isMainThread) } }
    }

    /// A scan landing warms it in the background, so the first menu doesn't build it on the main thread.
    @Test func warmBuildsOnceOffTheMainThread() async throws {
        let builds = Builds()
        let cache = TrashPolicyCache { builds.record(); return TrashSafetyPolicy(protectedPaths: ["/kept"]) }
        cache.warm()
        cache.warm()
        for _ in 0..<200 where builds.count == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(cache.current.refusal(forPath: "/kept", identity: nil) == .protectedLocation)
        #expect(builds.count == 1 && builds.onMain == 0)

        cache.invalidate()
        _ = cache.current
        #expect(builds.count == 2)
    }
}
