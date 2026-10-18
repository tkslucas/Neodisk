// The tree conformances are declarations only (signatures already match); hit-testers get CGPoint overloads.

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import NeodiskKit
import SunburstCore

extension FileNodeRecord: SunburstNode {}

extension FileTreeStore: SunburstTreeReading {}

extension SunburstHitTestIndex {
    package nonisolated func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        segment(
            atX: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }
}

extension SunburstHitTester {
    package nonisolated static func segment(
        at point: CGPoint,
        in size: CGSize,
        segments: [SunburstSegment]
    ) -> SunburstSegment? {
        segment(
            atX: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height),
            segments: segments
        )
    }
}

extension SunburstCenterHitTester {
    package nonisolated static func contains(
        point: CGPoint,
        in size: CGSize,
        radius: Double = SunburstLayout.centerRadius
    ) -> Bool {
        contains(
            atX: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height),
            radius: radius
        )
    }
}
