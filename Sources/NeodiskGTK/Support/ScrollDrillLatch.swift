//
//  ScrollDrillLatch.swift
//  NeodiskGTK
//
//  Ctrl+scroll as a pinch for the views that drill instead of zooming (the
//  flat treemap and the sunburst): X11 delivers no touchpad pinch, and a
//  mouse has none. Like PinchDrillRecognizer, one deliberate burst commits
//  one drill and then latches until the scrolling pauses, so a long flick
//  can't tunnel through several levels.
//

import CGtk
import Foundation
import NeodiskAppModel

@MainActor
final class ScrollDrillLatch {
    private var accumulated = 0.0
    private var didFire = false
    private var resetTask: Task<Void, Never>?

    /// A wheel notch commits at once; touchpad scrolling needs a short
    /// deliberate stroke (in surface pixels).
    private static let touchpadThreshold = 40.0
    private static let idleReset = Duration.milliseconds(250)

    /// Feeds one scroll event's vertical delta. Returns a direction once per
    /// burst: scrolling up (away from you) drills in, down drills out.
    func feed(dy: Double, unit: GdkScrollUnit) -> SunburstPinchDirection? {
        armReset()
        guard !didFire else { return nil }
        accumulated += dy
        let threshold = unit == GDK_SCROLL_UNIT_WHEEL ? 1.0 : Self.touchpadThreshold
        guard abs(accumulated) >= threshold else { return nil }
        didFire = true
        return accumulated < 0 ? .drillIn : .drillOut
    }

    private func armReset() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.idleReset)) != nil else { return }
            self?.accumulated = 0
            self?.didFire = false
        }
    }
}
