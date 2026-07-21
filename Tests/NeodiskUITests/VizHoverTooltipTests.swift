import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The tooltip content model is view-model-free, so its primary/secondary
/// lines can be exercised directly. `swift test` has no `.lproj` in
/// `Bundle.main`, so `NSLocalizedString` returns the English key templates —
/// which is exactly the source phrasing being checked here.
@Suite struct VizHoverTooltipTests {
    @Test func testItemLinesShowSizeAndPercentOfDrillRoot() {
        let data = VizHoverTooltipData(
            kind: .item(name: "Report.pdf"),
            sizeBytes: 18,
            basisBytes: 100,
            basisName: "Projects"
        )
        #expect(data.primaryText == "Report.pdf")

        let size = NeodiskFormatters.size(18)
        let percent = NeodiskFormatters.percentage(part: 18, total: 100)
        #expect(percent != nil)
        // "<size> · <percent> of Projects"
        #expect(data.secondaryText.contains(size))
        #expect(data.secondaryText.contains(percent!))
        #expect(data.secondaryText.contains("of Projects"))
    }

    @Test func testItemDropsPercentWhenBasisUnknown() {
        let data = VizHoverTooltipData(
            kind: .item(name: "Loose.txt"),
            sizeBytes: 4096,
            basisBytes: 0,
            basisName: ""
        )
        // No basis to divide by: the detail line is just the size.
        #expect(data.secondaryText == NeodiskFormatters.size(4096))
    }

    @Test func testCloudMovieUsesExistingCategorySymbolAndCloudGlyph() {
        let movie = FileNodeRecord(
            id: "/Cloud/movie.mov",
            url: URL(filePath: "/Cloud/movie.mov"),
            name: "movie.mov",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 2048,
            descendantFileCount: 1,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false,
            isDataless: true
        )
        let data = VizHoverTooltipData(
            item: movie,
            sizeBytes: movie.logicalSize,
            basisBytes: 4096,
            basisName: "Cloud"
        )

        #expect(data.itemSymbolName == "film.fill")
        #expect(data.showsCloudGlyph)
    }

    @Test func testAggregateTitleAndPercent() {
        let data = VizHoverTooltipData(
            kind: .aggregate(itemCount: 12),
            sizeBytes: 25,
            basisBytes: 100,
            basisName: "Downloads"
        )
        #expect(data.primaryText.contains("smaller items"))
        #expect(data.secondaryText.contains("of Downloads"))
    }

    @Test func testFreeSpaceLines() {
        let data = VizHoverTooltipData(
            kind: .freeSpace,
            sizeBytes: 42,
            basisBytes: 100,
            basisName: "Macintosh HD"
        )
        // Title is "Free space · <size>"; the percent basis is irrelevant.
        #expect(data.primaryText.hasPrefix("Free space · "))
        #expect(data.primaryText.contains(NeodiskFormatters.size(42)))
        #expect(data.secondaryText == "Space available on this volume.")
    }

    @Test func testHiddenSpaceReusesPurgeableExplanation() {
        let data = VizHoverTooltipData(
            kind: .hiddenSpace,
            sizeBytes: 99,
            basisBytes: 100,
            basisName: "Macintosh HD"
        )
        #expect(data.primaryText.hasPrefix("Hidden space · "))
        #expect(
            data.secondaryText
                == "Purgeable space, local snapshots, and files the scan could not see."
        )
    }
}
