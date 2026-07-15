//
//  VolumeBarDataTests.swift
//  Neodisk
//
//  The sidebar capacity bar's data model: category segments plus the
//  uncategorized remainder tile the scanned tree, the hidden tail uses the
//  same used-minus-scanned formula as the sunburst legend, and the free
//  track states the Finder-style available figure.
//

import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct VolumeBarDataTests {
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

    @Test func segmentsTileScannedTreeAndHiddenMatchesSharedFormula() {
        let data = VolumeBarData.make(
            space: space,
            sidecar: sidecar(categories: [
                PersistedKindStat(kindID: "cat-images", size: 300, count: 3),
                PersistedKindStat(kindID: "cat-other", size: 100, count: 1),
            ]),
            scannedBytes: 500,
            palette: .standard
        )

        // 300 images + (100 + 100 uncategorized) other, then the hidden tail.
        #expect(data.segments.map(\.id) == ["cat-images", "cat-other", "unscanned"])
        #expect(data.segments.map(\.size) == [300, 200, 100])
        // Hidden = used (600) − scanned (500), the sunburst legend's number.
        #expect(data.segments.last?.size == space.hiddenSpaceBytes(scannedBytes: 500))
        #expect(data.availableSize == 400)
        // Segments + free tile the volume exactly.
        #expect(data.segments.map(\.size).reduce(0, +) + (data.availableSize ?? 0) == 1_000)
    }

    @Test func uncategorizedRemainderCreatesOtherSegmentWhenAbsent() {
        let data = VolumeBarData.make(
            space: space,
            sidecar: sidecar(categories: [
                PersistedKindStat(kindID: "cat-images", size: 300, count: 3)
            ]),
            scannedBytes: 450,
            palette: .standard
        )

        #expect(data.segments.first { $0.id == "cat-other" }?.size == 150)
    }

    @Test func overCountedScanYieldsNoHiddenSegment() {
        // Scans can over-count real usage (shared blocks); the bar must not
        // render a negative or phantom hidden tail.
        let data = VolumeBarData.make(
            space: space,
            sidecar: sidecar(categories: [
                PersistedKindStat(kindID: "cat-images", size: 700, count: 3)
            ]),
            scannedBytes: 700,
            palette: .standard
        )

        #expect(!data.segments.contains { $0.id == "unscanned" })
    }

    @Test func missingSpaceInfoYieldsEmptyBar() {
        let data = VolumeBarData.make(
            space: nil,
            sidecar: sidecar(categories: []),
            scannedBytes: 100,
            palette: .standard
        )
        #expect(data == .empty)
    }
}
