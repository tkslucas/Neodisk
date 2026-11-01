import CoreGraphics
import Testing
@testable import NeodiskUI

/// The path bar collapses middle folders like a path control: first and last stay, the last never drops.
@Suite struct PathBarFitTests {
    private func fit(_ widths: [CGFloat], _ available: CGFloat) -> [Int?] {
        PathBarFit.shownIndices(widths: widths, separator: 8, ellipsis: 20, available: available)
    }

    @Test func everythingShowsWhenItFits() {
        #expect(fit([50, 50, 50], 166) == [0, 1, 2])
    }

    @Test func middleFoldersCollapseNearestTheRootFirst() {
        // 6 crumbs of 50: all need 340. Root, ellipsis, then as many of the last ones as fit.
        let shown = fit(Array(repeating: 50, count: 6), 260)
        #expect(shown == [0, nil, 3, 4, 5])
        #expect(PathBarFit.hiddenIndices(shown: shown, count: 6) == [1, 2])
    }

    @Test func theLastStaysWhenOnlyItAndTheEllipsisFit() {
        let shown = fit([80, 50, 50, 200], 240)
        #expect(shown == [nil, 3])
        #expect(PathBarFit.hiddenIndices(shown: shown, count: 4) == [0, 1, 2])
    }

    @Test func oneOrTwoCrumbsNeverCollapse() {
        #expect(fit([300, 300], 100) == [0, 1])
        #expect(fit([300], 100) == [0])
    }
}
