//
//  SunburstMidpointColorTests.swift
//  Neodisk
//
//  Behavioral invariants of the size-midpoint branch coloring: hue equals
//  the global interval midpoint, files stay neutral but still displace the
//  hues after them, saturation halves its distance to pastel per depth, and
//  the coordinate is scan-root anchored.
//

import Foundation
import SunburstCore
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct SunburstMidpointColorTests {
    private func makeFolder(_ id: String, size: Int64) -> FileNodeRecord {
        makeTestDirectoryNode(id: id, name: String(id.split(separator: "/").last!), children: [
            makeTestFileNode(id: "\(id)/f", name: "f", size: size),
        ])
    }

    private func makeRoot(children: [FileNodeRecord]) -> FileTreeStore {
        let sorted = FileTreeStore.sortedChildren(children)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: sorted)
        return FileTreeStore(root: root, childrenByID: ["/root": sorted])
    }

    @Test func fourEqualFoldersLandOnTheQuarterMidpoints() throws {
        let store = makeRoot(children: [
            makeFolder("/root/a", size: 10),
            makeFolder("/root/b", size: 10),
            makeFolder("/root/c", size: 10),
            makeFolder("/root/d", size: 10),
        ])
        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let midpoints = segments.map(\.colorToken.midpoint).sorted()
        let expected = [0.125, 0.375, 0.625, 0.875]
        #expect(midpoints.count == 4)
        for (midpoint, target) in zip(midpoints, expected) {
            #expect(abs(midpoint - target) < 1e-9)
        }
    }

    @Test func dominantFirstFolderResolvesNearMidGreenNotRed() throws {
        // An 80% first folder starts at hue 0 but its midpoint is 0.4 —
        // the wheel's green region, never red.
        let store = makeRoot(children: [
            makeFolder("/root/big", size: 80),
            makeFolder("/root/small", size: 20),
        ])
        let segments = SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
        let big = try #require(segments.first { $0.nodeID == "/root/big" })
        #expect(abs(big.colorToken.midpoint - 0.4) < 1e-9)
    }

    @Test func largeFileBeforeAFolderShiftsItsHue() throws {
        // Files draw gray but still advance the color cursor, so a folder's
        // hue depends on the files sorted ahead of it.
        let withoutFile = makeRoot(children: [
            makeFolder("/root/sub", size: 20),
        ])
        let withFile = makeRoot(children: [
            makeTestFileNode(id: "/root/huge.bin", name: "huge.bin", size: 80),
            makeFolder("/root/sub", size: 20),
        ])
        func midpoint(in store: FileTreeStore) throws -> Double {
            try #require(
                SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
                    .first { $0.nodeID == "/root/sub" }
            ).colorToken.midpoint
        }
        #expect(abs(try midpoint(in: withoutFile) - 0.5) < 1e-9)
        #expect(abs(try midpoint(in: withFile) - 0.9) < 1e-9)

        let fileToken = try #require(
            SunburstLayout.segments(in: withFile, rootID: "/root", depthLimit: 1)
                .first { $0.nodeID == "/root/huge.bin" }
        ).colorToken
        #expect(fileToken.role == .file)
    }

    @Test func wheelSaturationHalvesItsDistanceToPastelPerDepth() {
        // First ring 0.75, then 0.625, 0.5625, … approaching 0.5;
        // brightness stays full at every depth.
        for (depth, saturation) in [(1, 0.75), (2, 0.625), (3, 0.5625), (4, 0.53125)] {
            let components = SunburstColorResolver.components(
                for: SunburstColorToken(midpoint: 0.3, depth: depth, role: .normal),
                palette: .standard
            )
            #expect(abs(components.saturation - saturation) < 1e-9, "depth \(depth)")
            #expect(components.brightness == 1.0)
            #expect(abs(components.hue - 0.3) < 1e-9)
        }
    }

    @Test func statusSwatchMatchesTheRenderedSegmentColor() throws {
        // branchColor derives the same token from the tree that the layout
        // bakes into segments — the status-bar swatch and the chart agree.
        let store = makeRoot(children: [
            makeFolder("/root/a", size: 3),
            makeFolder("/root/b", size: 1),
        ])
        let segment = try #require(
            SunburstLayout.segments(in: store, rootID: "/root", depthLimit: 1)
                .first { $0.nodeID == "/root/b" }
        )
        let swatch = SunburstColorResolver.branchColor(forNodeID: "/root/b", in: store)
        #expect(swatch == SunburstColorResolver.color(for: segment.colorToken))
    }
}
