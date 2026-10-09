//
//  Observation.swift
//  NeodiskGTK
//
//  Drives GTK widgets from @Observable state. `withObservationTracking`
//  reports the first change to anything `update` read, once; `track`
//  re-runs `update` on the next main-actor turn (after the mutation has
//  landed, and coalescing a burst of mutations into one refresh) and
//  re-registers — the same contract SwiftUI gives the macOS views.
//

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

/// Runs `update` now and again whenever any observable property it read
/// changes. Keep the token for as long as the binding should live: it's
/// weakly held, so a dropped token ends the binding after its first change.
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
