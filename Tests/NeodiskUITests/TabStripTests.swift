import CoreGraphics
import Testing
@testable import NeodiskUI

/// The statistics tab bar's fitting and live-reorder math.
struct TabStripTests {
    // Tabs a…e, 40pt wide each except c (60pt): slots at 10, 62, 114, 186, 238; the row ends at 278.
    private let strip = TabStrip(
        padding: 10, spacing: 12,
        widths: ["a": 40, "b": 40, "c": 60, "d": 40, "e": 40] as [String: CGFloat]
    )
    private let tabs = ["a", "b", "c", "d", "e"]

    @Test func everythingFitsAWideBar() {
        let fit = strip.fit(tabs, barWidth: 288, menuWidth: 16, active: "e")
        #expect(fit.shown == tabs)
        #expect(fit.overflow.isEmpty)
    }

    @Test func aNarrowBarSendsTheRestToTheMenu() {
        // 200 - 20 padding - 16 menu - 12 spacing leaves 152: a, b, c take 164, so two fit.
        let fit = strip.fit(tabs, barWidth: 200, menuWidth: 16, active: "a")
        #expect(fit.shown == ["a", "b"])
        #expect(fit.overflow == ["c", "d", "e"])
    }

    @Test func theActiveTabTakesTheLastSpotWhenItWouldOverflow() {
        let fit = strip.fit(tabs, barWidth: 200, menuWidth: 16, active: "d")
        #expect(fit.shown == ["a", "d"])
        #expect(fit.overflow == ["b", "c", "e"])
    }

    @Test func aWiderActiveTabPushesOutTheOnesItDoesntFitBeside() {
        // Room 152 fits a, b, d (144); c is 60 wide, so a, b, c would take 164.
        let fit = strip.fit(["a", "b", "d", "e", "c"], barWidth: 200, menuWidth: 16, active: "c")
        #expect(fit.shown == ["a", "c"])
        #expect(fit.overflow == ["b", "d", "e"])
    }

    @Test func slotsFollowTheWidths() {
        #expect(strip.slots(tabs) == ["a": 10, "b": 62, "c": 114, "d": 186, "e": 238])
    }

    @Test func aDraggedTabStaysInsideTheRow() {
        #expect(strip.clampedLeft(-50, of: "b", in: tabs) == 10)
        #expect(strip.clampedLeft(500, of: "b", in: tabs) == 238)
        #expect(strip.clampedLeft(500, of: "c", in: tabs) == 218)
        #expect(strip.clampedLeft(90, of: "b", in: tabs) == 90)
    }

    @Test func aTabPassesANeighborOnlyOnceItsMiddleCrossesTheNeighbors() {
        // b's middle is left + 20; c's middle is at 144.
        #expect(strip.reordered(tabs, dragging: "b", left: 123) == tabs)
        #expect(strip.reordered(tabs, dragging: "b", left: 62) == tabs)
        #expect(strip.reordered(tabs, dragging: "b", left: 11) == tabs)
        #expect(strip.reordered(tabs, dragging: "b", left: 125) == ["a", "c", "b", "d", "e"])
        // a's middle is at 30.
        #expect(strip.reordered(tabs, dragging: "b", left: 10) == ["b", "a", "c", "d", "e"])
    }

    @Test func aFastDragPassesEveryTabItCrossed() {
        #expect(strip.reordered(tabs, dragging: "a", left: 238) == ["b", "c", "d", "e", "a"])
        #expect(strip.reordered(tabs, dragging: "e", left: 10) == ["e", "a", "b", "c", "d"])
    }

    @Test func settlingDoesntSwapBack() {
        let once = strip.reordered(tabs, dragging: "b", left: 125)
        #expect(strip.reordered(once, dragging: "b", left: 125) == once)
        let back = strip.reordered(once, dragging: "b", left: 100)
        #expect(back == once)
    }
}
