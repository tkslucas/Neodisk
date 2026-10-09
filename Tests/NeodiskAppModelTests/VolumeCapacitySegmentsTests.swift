//
//  VolumeCapacitySegmentsTests.swift
//  NeodiskAppModelTests
//
//  The sidebar capacity bar's segments, shared by both apps: category
//  segments plus the uncategorized remainder tile the scanned tree, and the
//  hidden tail uses the same used-minus-scanned formula as the sunburst
//  legend.
//

import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

@Suite struct VolumeCapacitySegmentsTests {
    private let space = VolumeSpaceInfo(
        totalCapacity: 1_000,
        availableCapacity: 400,
        strictlyFreeCapacity: 300
    )

    private func sidecar(categories: [PersistedKindStat]) -> KindStatsSidecar {
        KindStatsSidecar(
            targetPath: "/",
            finishedAt: Date(timeIntervalSince1970: 0),
            nodeCount: 1,
            categories: categories,
            types: []
        )
    }

    @Test func segmentsTileScannedTreeThenHiddenTail() {
        let segments = VolumeCapacitySegments.make(
            space: space,
            sidecar: sidecar(categories: [
                PersistedKindStat(kindID: "cat-images", size: 300, count: 3),
                PersistedKindStat(kindID: "cat-other", size: 100, count: 1),
            ]),
            scannedBytes: 500,
            palette: .standard
        )

        // 300 images + (100 + 100 uncategorized) other, then the hidden tail.
        #expect(segments.map(\.id) == ["cat-images", "cat-other", "unscanned"])
        #expect(segments.map(\.size) == [300, 200, 100])
        #expect(segments.last?.size == space.hiddenSpaceBytes(scannedBytes: 500))
        #expect(segments.map(\.fraction) == [0.3, 0.2, 0.1])
    }

    @Test func overCountedScanYieldsNoHiddenSegment() {
        let segments = VolumeCapacitySegments.make(
            space: space,
            sidecar: sidecar(categories: [
                PersistedKindStat(kindID: "cat-images", size: 700, count: 3)
            ]),
            scannedBytes: 700,
            palette: .standard
        )
        #expect(!segments.contains { $0.id == "unscanned" })
    }

    @Test func missingSpaceInfoYieldsNoSegments() {
        let segments = VolumeCapacitySegments.make(
            space: nil,
            sidecar: sidecar(categories: []),
            scannedBytes: 100,
            palette: .standard
        )
        #expect(segments.isEmpty)
    }
}
