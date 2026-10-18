// `track` re-runs `update` on the next main-actor turn (coalescing bursts) and re-registers,
// the same contract SwiftUI gives the macOS views.

import Dispatch
import Observation

/// A live binding from observable state to widgets. Dropping the token (or
/// calling `cancel`) stops the refreshes.
@MainActor
final class ObservationToken {
    fileprivate var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

/// The token is weakly held: dropping it ends the binding after its first change.
@MainActor
func track(_ update: @escaping @MainActor () -> Void) -> ObservationToken {
    let token = ObservationToken()
    observe(update, token: token)
    return token
}

@MainActor
private func observe(_ update: @escaping @MainActor () -> Void, token: ObservationToken) {
    guard !token.isCancelled else { return }
    withObservationTracking {
        update()
    } onChange: { [weak token] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let token else { return }
                observe(update, token: token)
            }
        }
    }
}
