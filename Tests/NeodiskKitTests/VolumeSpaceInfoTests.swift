import Testing
import Foundation
@testable import NeodiskKit

@Suite struct VolumeSpaceInfoTests {
    @Test func testPurgeableIsAvailableMinusStrictlyFree() {
        let info = VolumeSpaceInfo(
            totalCapacity: 1_000,
            availableCapacity: 400,
            strictlyFreeCapacity: 250
        )
        #expect(info.purgeableBytes == 150)
        #expect(info.usedBytes == 600)
    }

    @Test func testPurgeableIsZeroWithoutStrictlyFreeFigure() {
        let info = VolumeSpaceInfo(
            totalCapacity: 1_000,
            availableCapacity: 400,
            strictlyFreeCapacity: nil
        )
        #expect(info.purgeableBytes == 0)
    }

    @Test func testPurgeableNeverNegative() {
        // Available and strictly-free come from separate reads; a racing
        // deletion can momentarily order them the wrong way around.
        let info = VolumeSpaceInfo(
            totalCapacity: 1_000,
            availableCapacity: 300,
            strictlyFreeCapacity: 350
        )
        #expect(info.purgeableBytes == 0)
    }

    @Test func testHiddenSpaceIsUsedMinusScanned() {
        let info = VolumeSpaceInfo(
            totalCapacity: 1_000,
            availableCapacity: 400,
            strictlyFreeCapacity: 250
        )
        #expect(info.hiddenSpaceBytes(scannedBytes: 450) == 150)
    }

    @Test func testHiddenSpaceIsNilWhenScanCoversUsedSpace() {
        let info = VolumeSpaceInfo(
            totalCapacity: 1_000,
            availableCapacity: 400,
            strictlyFreeCapacity: nil
        )
        #expect(info.hiddenSpaceBytes(scannedBytes: 600) == nil)
        // Over-counting scans (undeduplicated sharing) must not surface as
        // negative hidden space.
        #expect(info.hiddenSpaceBytes(scannedBytes: 700) == nil)
    }

    @Test func testMakePrefersImportantUsageOverPlainAvailable() {
        let info = VolumeSpaceInfo.make(
            totalCapacity: 1_000,
            availableCapacity: 250,
            availableCapacityForImportantUsage: 400
        )
        #expect(info?.availableCapacity == 400)
        #expect(info?.strictlyFreeCapacity == 250)
        #expect(info?.usedBytes == 600)
    }

    @Test func testMakeFallsBackToPlainAvailable() {
        let info = VolumeSpaceInfo.make(
            totalCapacity: 1_000,
            availableCapacity: 250,
            availableCapacityForImportantUsage: nil
        )
        #expect(info?.availableCapacity == 250)
        #expect(info?.purgeableBytes == 0)
    }

    @Test func testMakeRequiresTotalAndSomeAvailableFigure() {
        #expect(VolumeSpaceInfo.make(
            totalCapacity: nil,
            availableCapacity: 250,
            availableCapacityForImportantUsage: 400
        ) == nil)
        #expect(VolumeSpaceInfo.make(
            totalCapacity: 1_000,
            availableCapacity: nil,
            availableCapacityForImportantUsage: nil
        ) == nil)
    }

    @Test func testLoadReadsARealVolume() {
        let info = VolumeSpaceInfo.load(for: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(info != nil)
        if let info {
            #expect(info.totalCapacity > 0)
            #expect(info.availableCapacity <= info.totalCapacity)
            #expect(info.usedBytes + info.availableCapacity == info.totalCapacity)
        }
    }
}
