//
//  SunburstCore+Neodisk.swift
//  Neodisk
//
//  Bridges SunburstCore to Neodisk's model and coordinate types: FileTreeStore
//  and FileNodeRecord conform to the core tree protocols (their signatures
//  already match, so the conformances are declarations only), and the
//  Double-based hit-testers get thin CGPoint/CGSize overloads for the AppKit
//  call sites.
//

import CoreGraphics
import NeodiskKit
import SunburstCore

extension FileNodeRecord: SunburstNode {}

extension FileTreeStore: SunburstTreeReading {}

extension SunburstHitTestIndex {
    nonisolated func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        segment(
            atX: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }
}

extension SunburstHitTester {
    nonisolated static func segment(
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
    nonisolated static func contains(
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
