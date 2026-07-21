import AppKit
import Testing
@testable import NeodiskUI

@MainActor
struct OutlineScrollTests {
    @Test func topOcclusionRevealsRowsBelowTheTableHeader() {
        let scrollView = makeScrollView()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 37, y: 100))
        let coveredRow = NSRect(x: 0, y: 110, width: 500, height: 20)

        scrollOutlineRowVertically(coveredRow, in: scrollView, topOcclusion: 28)

        #expect(clip.bounds.minX == 37)
        #expect(clip.bounds.minY == coveredRow.minY - 28)
    }

    @Test func unobscuredRowsDoNotMoveTheViewport() {
        let scrollView = makeScrollView()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 37, y: 100))
        let originalOrigin = clip.bounds.origin
        let visibleRow = NSRect(x: 0, y: 140, width: 500, height: 20)

        scrollOutlineRowVertically(visibleRow, in: scrollView, topOcclusion: 28)

        #expect(clip.bounds.origin == originalOrigin)
    }

    @Test func rowsBelowTheViewportStillAlignToItsBottom() {
        let scrollView = makeScrollView()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 37, y: 100))
        let viewportHeight = clip.bounds.height
        let rowBelow = NSRect(
            x: 0, y: clip.bounds.maxY + 10, width: 500, height: 20
        )

        scrollOutlineRowVertically(rowBelow, in: scrollView, topOcclusion: 28)

        #expect(clip.bounds.minX == 37)
        #expect(clip.bounds.minY == rowBelow.maxY - viewportHeight)
    }

    private func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        return scrollView
    }
}
