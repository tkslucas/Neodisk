// The window subtitle: volume scans state the Finder/Disk Utility used, capacity and free figures; folder and
// cloud scans state what the scan accounted for.

import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct WindowTitleTests {
    @Test func volumeScansStateUsedOfCapacityAndFree() {
        #expect(ContentView.windowSubtitle(
            targetKind: .volume,
            finderUsedBytes: 411_000_000_000,
            freeBytes: 83_000_000_000,
            scannedTotalBytes: 380_000_000_000
        ) == "411 GB of 494 GB used · 83 GB free")
    }

    @Test func volumeScansWithoutFreeSpaceStateUsedAlone() {
        #expect(ContentView.windowSubtitle(
            targetKind: .volume,
            finderUsedBytes: 600_000_000_000,
            freeBytes: nil,
            scannedTotalBytes: 550_000_000_000
        ) == "600 GB")
    }

    @Test func volumeScansFallBackToScannedTotalWithoutCapacityInfo() {
        #expect(ContentView.windowSubtitle(
            targetKind: .volume,
            finderUsedBytes: nil,
            freeBytes: nil,
            scannedTotalBytes: 550_000_000_000
        ) == "550 GB")
    }

    @Test func folderScansStateScannedTotal() {
        #expect(ContentView.windowSubtitle(
            targetKind: .folder,
            finderUsedBytes: 600_000_000_000,
            freeBytes: 83_000_000_000,
            scannedTotalBytes: 42_000_000_000
        ) == "42 GB")
    }

    @Test func missingNumbersLeaveTheSubtitleEmpty() {
        #expect(ContentView.windowSubtitle(
            targetKind: .folder,
            finderUsedBytes: nil,
            freeBytes: nil,
            scannedTotalBytes: nil
        ) == "")
    }
}
