import Foundation
import Testing
@testable import NeodiskUI

/// The sidebar background-scan bar's native hover help. The detail line is
/// view-model-free, so its composition can be exercised directly. Percent and
/// count use the host locale's conventions, so the checks recompute the parts
/// rather than hardcoding
/// English digits.
@Suite struct SidebarScanTooltipTests {
    @Test func testDetailLineComposesPercentThenItemCount() {
        let data = SidebarScanTooltipData(progressFraction: 0.42, itemCount: 12345)
        let percent = 0.42.formatted(.percent.precision(.fractionLength(0)))
        let count = 12345.formatted()

        // "42% · 12,345 items" — percent, the middle dot, then the count.
        #expect(data.detailText.contains(percent))
        #expect(data.detailText.contains(count))
        #expect(data.detailText.contains("·"))
        let percentAt = data.detailText.range(of: percent)!
        let countAt = data.detailText.range(of: count)!
        #expect(percentAt.lowerBound < countAt.lowerBound)
    }

    @Test func testDetailLineShowsWholePercents() {
        // fractionLength(0) keeps the percent whole, like the scan strip.
        let data = SidebarScanTooltipData(progressFraction: 0.006, itemCount: 0)
        #expect(data.detailText.contains(0.006.formatted(.percent.precision(.fractionLength(0)))))
        #expect(data.detailText.contains(0.formatted()))
    }
}
