//
//  PinchDrillRecognizer.swift
//  NeodiskAppModel
//
//  The shared "one drill per pinch" state machine used by every
//  pinch-to-drill surface: on the Mac the flat treemap (TreemapController),
//  the sunburst chart's AppKit overlay (SunburstInteractionOverlay), and the
//  sunburst legend's SwiftUI MagnifyGesture (SunburstLegendList); on Linux
//  the flat treemap and sunburst views. A deliberate pinch
//  accumulates to ~±1; the first crossing of `threshold` commits one drill and
//  latches until the fingers lift, so a long pinch can never tunnel through
//  several levels at once and trackpad noise never fires.
//
//  Two feed styles, one latch: AppKit's `NSEvent.magnification` arrives as
//  incremental deltas (`accumulate`), SwiftUI's `MagnifyGesture` and GTK's
//  zoom gesture report an absolute ratio around 1 (`update(ratio:)`). Both
//  reduce to a signed magnitude tested against the same threshold.
//

import Foundation

package enum SunburstPinchDirection: Sendable {
    /// Fingers spreading apart — drill into the arc under the cursor.
    case drillIn
    /// Fingers pinching together — go up to the parent folder.
    case drillOut
}

package struct PinchDrillRecognizer: Sendable {
    /// Accumulated |magnification| that commits a drill. A full deliberate
    /// pinch sums to ~1, so this triggers well before the fingers finish
    /// without firing on trackpad noise.
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

    /// Feeds one incremental magnification delta (`NSEvent.magnification`).
    /// Returns a direction exactly once per gesture, when the running sum
    /// first crosses `threshold`.
    package mutating func accumulate(_ delta: CGFloat) -> SunburstPinchDirection? {
        accumulated += delta
        return fire(ifCrossed: accumulated)
    }

    /// Feeds an absolute magnification ratio (`MagnifyGesture`, 1 = no change).
    /// A cancelled gesture never delivers an end event, so a fresh gesture
    /// restarting near ratio 1 clears the stale latch here.
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
