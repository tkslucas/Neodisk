// The live Trash policy reads the disk, so it's built off the main thread when a scan lands, before the first menu
// asks; a menu that beats the warm-up builds it in place.

import NeodiskKit

@MainActor
package final class TrashPolicyCache {
    package var make: @Sendable () -> TrashSafetyPolicy
    private var policy: TrashSafetyPolicy?
    /// Bumped by `invalidate`, so a warm-up started before a mount change can't store a stale policy.
    private var generation = 0
    private var isWarming = false

    package init(make: @escaping @Sendable () -> TrashSafetyPolicy = { TrashSafetyPolicy.live() }) {
        self.make = make
    }

    package var current: TrashSafetyPolicy {
        if let policy { return policy }
        let built = make()
        policy = built
        return built
    }

    package func warm() {
        guard policy == nil, !isWarming else { return }
        isWarming = true
        let make = make
        let generation = generation
        Task {
            let built = await Task.detached(priority: .utility) { make() }.value
            guard generation == self.generation else { return }
            isWarming = false
            if policy == nil { policy = built }
        }
    }

    /// Mounts changed: the next use builds a new one.
    package func invalidate() {
        policy = nil
        generation += 1
        isWarming = false
    }

    /// A fresh policy built off the main thread (before moves), kept for the menus after.
    package func rebuild() async -> TrashSafetyPolicy {
        let make = make
        let generation = generation
        let built = await Task.detached(priority: .userInitiated) { make() }.value
        // A mount change meanwhile: the menus build a newer one; this move still uses what it built.
        guard generation == self.generation else { return built }
        invalidate()
        policy = built
        return built
    }
}
