// Drives toolkit views from @Observable state outside SwiftUI: `observeChanges` re-runs `update` on the next
// main-actor turn after anything it read changes (coalescing bursts), then watches again. The Windows app
// uses it; the GTK app's `track` is the same contract.

import Dispatch
import Observation

/// A live binding; cancelling it (or dropping it) stops the refreshes.
@MainActor
package final class ChangeObservation {
    fileprivate var isCancelled = false

    package func cancel() {
        isCancelled = true
    }
}

/// The observation is weakly held: dropping it ends the binding after its next change.
@MainActor
package func observeChanges(_ update: @escaping @MainActor () -> Void) -> ChangeObservation {
    let observation = ChangeObservation()
    observe(update, observation: observation)
    return observation
}

@MainActor
private func observe(_ update: @escaping @MainActor () -> Void, observation: ChangeObservation) {
    guard !observation.isCancelled else { return }
    withObservationTracking {
        update()
    } onChange: { [weak observation] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let observation else { return }
                observe(update, observation: observation)
            }
        }
    }
}
