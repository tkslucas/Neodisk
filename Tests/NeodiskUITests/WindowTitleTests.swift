//
//  WindowTitleTests.swift
//  Neodisk
//
//  The window title's total: volume scans state the Finder/Disk Utility
//  "used" figure; folder and cloud scans state what the scan accounted for.
//

import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct WindowTitleTests {
    @Test func volumeScansTitleFinderUsedSpace() {
        #expect(ContentView.windowTitle(
            targetName: "Macintosh HD",
            targetKind: .volume,
            finderUsedBytes: 600_000_000_000,
            scannedTotalBytes: 550_000_000_000
        ) == "Macintosh HD (600 GB)")
    }

    @Test func volumeScansFallBackToScannedTotalWithoutCapacityInfo() {
        #expect(ContentView.windowTitle(
            targetName: "NetworkVolume",
            targetKind: .volume,
            finderUsedBytes: nil,
            scannedTotalBytes: 550_000_000_000
        ) == "NetworkVolume (550 GB)")
    }

    @Test func folderScansTitleScannedTotal() {
        #expect(ContentView.windowTitle(
            targetName: "Documents",
            targetKind: .folder,
            finderUsedBytes: 600_000_000_000,
            scannedTotalBytes: 42_000_000_000
        ) == "Documents (42 GB)")
    }

    @Test func missingNumbersDegradeGracefully() {
        #expect(ContentView.windowTitle(
            targetName: "Documents",
            targetKind: .folder,
            finderUsedBytes: nil,
            scannedTotalBytes: nil
        ) == "Documents")
        #expect(ContentView.windowTitle(
            targetName: nil,
            targetKind: nil,
            finderUsedBytes: nil,
            scannedTotalBytes: nil
        ) == "Neodisk")
    }
}
