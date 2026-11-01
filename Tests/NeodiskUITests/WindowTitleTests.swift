// The window subtitle's total: volume scans state the Finder/Disk Utility
// "used" figure; folder and cloud scans state what the scan accounted for.

import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct WindowTitleTests {
    @Test func volumeScansStateFinderUsedSpace() {
        #expect(ContentView.windowSubtitle(
            targetKind: .volume,
            finderUsedBytes: 600_000_000_000,
            scannedTotalBytes: 550_000_000_000
        ) == "600 GB")
    }

    @Test func volumeScansFallBackToScannedTotalWithoutCapacityInfo() {
        #expect(ContentView.windowSubtitle(
            targetKind: .volume,
            finderUsedBytes: nil,
            scannedTotalBytes: 550_000_000_000
        ) == "550 GB")
    }

    @Test func folderScansStateScannedTotal() {
        #expect(ContentView.windowSubtitle(
            targetKind: .folder,
            finderUsedBytes: 600_000_000_000,
            scannedTotalBytes: 42_000_000_000
        ) == "42 GB")
    }

    @Test func missingNumbersLeaveTheSubtitleEmpty() {
        #expect(ContentView.windowSubtitle(
            targetKind: .folder,
            finderUsedBytes: nil,
            scannedTotalBytes: nil
        ) == "")
    }
}
