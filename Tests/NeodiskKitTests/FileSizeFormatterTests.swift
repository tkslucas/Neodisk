import Testing
import Foundation
@testable import NeodiskKit

@Suite struct FileSizeFormatterTests {
    @Test func testSmallSizesUseByteUnits() {
        #expect(NeodiskFormatters.size(0).localizedCaseInsensitiveContains("byte"))
        #expect(NeodiskFormatters.size(1) == "1 byte")
        #expect(NeodiskFormatters.size(512) == "512 bytes")
        #expect(NeodiskFormatters.size(1_024) == "1 KB")
    }

    @Test func testPercentageReturnsNilForNonPositiveTotal() {
        #expect(NeodiskFormatters.percentage(part: 1, total: 0) == nil)
        #expect(NeodiskFormatters.percentage(part: 1, total: -10) == nil)
    }

    @Test func testPercentageFormatsRatioWithOneFractionDigit() {
        #expect(NeodiskFormatters.percentage(part: 0, total: 10) == "0.0%")
        #expect(NeodiskFormatters.percentage(part: 1, total: 4) == "25.0%")
        #expect(NeodiskFormatters.percentage(part: 1, total: 3) == "33.3%")
        #expect(NeodiskFormatters.percentage(part: 1, total: 1) == "100.0%")
    }

    @Test func testPercentageDoesNotClampAboveOneHundredPercent() {
        // A child can exceed its container (e.g. hard-link dedup or
        // allocated-vs-logical accounting); the formatter reports the raw ratio.
        #expect(NeodiskFormatters.percentage(part: 3, total: 2) == "150.0%")
    }

    @Test func testSizeDeltaSignsAndUnchangedDot() {
        // The outline measures column widths from these exact strings and
        // DeltaLabel renders them; the three shapes are the contract.
        #expect(NeodiskFormatters.sizeDelta(0) == "·")
        #expect(NeodiskFormatters.sizeDelta(1500) == "+\(NeodiskFormatters.size(1500))")
        #expect(NeodiskFormatters.sizeDelta(-1500) == "−\(NeodiskFormatters.size(1500))")
    }
}
