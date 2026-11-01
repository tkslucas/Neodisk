import Foundation
import Testing
@testable import NeodiskAppModel

@Suite struct DisplayFormattersTests {
    /// A timeline date that lags the clock (the repeated hour when daylight saving ends) never makes a past scan
    /// read as a future one.
    @Test func aLaggingTimelineDateStillReadsThePastAsPast() {
        let scanned = Date().addingTimeInterval(-17 * 60)
        let laggingNow = Date().addingTimeInterval(-60 * 60)
        #expect(DisplayFormatters.relativeDate(scanned, relativeTo: laggingNow)
            == DisplayFormatters.relativeDate(scanned))
    }
}
