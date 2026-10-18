// "One drill per pinch" for every pinch-to-drill surface: the first crossing of `threshold` commits and
// latches until the fingers lift, so a long pinch never tunnels several levels and noise never fires.

import Foundation

package enum SunburstPinchDirection: Sendable {
    /// Fingers spreading apart — drill into the arc under the cursor.
    case drillIn
    /// Fingers pinching together — go up to the parent folder.
    case drillOut
}

package struct PinchDrillRecognizer: Sendable {
    /// A deliberate pinch sums to ~1, so this fires well before the fingers finish, but not on noise.
    package static let threshold: CGFloat = 0.1

    private var accumulated: CGFloat = 0
    private var didFire = false

    /// Resets for a new gesture (AppKit `.began`). The SwiftUI feed doesn't
    /// get a begin phase and relies on `update(ratio:)`'s auto-reset instead.
    package init() {}

    package mutating func begin() {
        accumulated = 0
        didFire = false
    }

    /// Returns a direction exactly once per gesture.
    package mutating func accumulate(_ delta: CGFloat) -> SunburstPinchDirection? {
        accumulated += delta
        return fire(ifCrossed: accumulated)
    }

    /// A cancelled gesture never delivers an end event, so a fresh one restarting near 1 clears the stale
    /// latch.
    package mutating func update(ratio: CGFloat) -> SunburstPinchDirection? {
        if didFire, abs(ratio - 1) < 0.05 {
            didFire = false
        }
        return fire(ifCrossed: ratio - 1)
    }

    /// Ends the gesture (AppKit `.ended`/`.cancelled`, SwiftUI `onEnded`).
    package mutating func end() {
        accumulated = 0
        didFire = false
    }

    private mutating func fire(ifCrossed magnitude: CGFloat) -> SunburstPinchDirection? {
        guard !didFire, abs(magnitude) >= Self.threshold else { return nil }
        didFire = true
        return magnitude > 0 ? .drillIn : .drillOut
    }
}
