import Foundation
import Testing
import NeodiskKit
@testable import NeodiskAppModel

struct SidebarSectionsTests {
    @Test func roundTripsHiddenAndCollapsedInSectionOrder() {
        var state = SidebarSectionState()
        state.setShown(.folders, false)
        state.setShown(.volumes, false)
        state.setExpanded(.cleanup, false)
        #expect(state.storedHidden == "volumes,folders")
        #expect(state.storedCollapsed == "cleanup")
        #expect(SidebarSectionState(hidden: state.storedHidden, collapsed: state.storedCollapsed) == state)
        #expect(SidebarSectionState(hidden: "bogus,,folders").hidden == [.folders])
    }

    /// Cleanup shows when it's enabled and not hidden; hiding it is stored like any section.
    @Test func cleanupNeedsEnabledAndShown() {
        var state = SidebarSectionState()
        #expect(state.isShown(.cleanup, cleanupEnabled: true))
        #expect(!state.isShown(.cleanup, cleanupEnabled: false))
        state.setShown(.cleanup, false)
        #expect(state.storedHidden == "cleanup")
        #expect(!state.isShown(.cleanup, cleanupEnabled: true))
        #expect(state.isShown(.volumes, cleanupEnabled: false))
    }

    @Test func revealShowsAndExpands() {
        var state = SidebarSectionState(hidden: "folders", collapsed: "folders,cleanup")
        state.reveal(.folders)
        state.reveal(.cleanup)
        #expect(state.isShown(.folders, cleanupEnabled: true))
        #expect(state.isExpanded(.folders) && state.isExpanded(.cleanup))
    }

    @Test func rowShowsVolumeFreeAndUsedAndFolderScannedSize() throws {
        let space = try #require(VolumeSpaceInfo.make(
            totalCapacity: 2_000_000_000_000,
            availableCapacity: 512_000_000_000,
            availableCapacityForImportantUsage: 640_000_000_000
        ))
        // Available counts purgeable space.
        #expect(SidebarRowText.size(space: space, scannedBytes: nil) == "640 GB free")
        #expect(SidebarRowText.size(space: nil, scannedBytes: 1_500_000) == "1.5 MB")
        #expect(SidebarRowText.size(space: nil, scannedBytes: nil) == nil)
        // Used is capacity minus available, as the trailing free figure counts it.
        #expect(SidebarRowText.usage(space: space) == "1.36 TB of 2 TB used")
        #expect(SidebarRowText.usage(space: nil) == nil)
        #expect(SidebarRowText.scanned(nil) == nil)
    }

    @Test func refusedFolderAndAheadClockReadPlainly() {
        #expect(SidebarRowText.size(space: nil, scannedBytes: 0, unreadable: true) == "Couldn't be read")
        #expect(SidebarRowText.size(space: nil, scannedBytes: 0) == NeodiskFormatters.size(0))
        // A scan date a little ahead of the once-a-minute clock is still the past. The formatter never measures
        // from before the real clock, so `now` is the real one.
        let now = Date()
        #expect(SidebarRowText.scanned(now.addingTimeInterval(90), now: now) == "Scanned just now")
        #expect(SidebarRowText.scanned(now.addingTimeInterval(-30), now: now) == "Scanned just now")
        #expect(SidebarRowText.scanned(now.addingTimeInterval(-600), now: now) != "Scanned just now")
    }

    @Test func cleanupSummaryCountsItems() {
        #expect(CleanupText.summary(count: 0, totalSize: 0) == nil)
        #expect(CleanupText.summary(count: 1, totalSize: 8_000) == "8 KB · 1 item")
        #expect(CleanupText.summary(count: 3, totalSize: 1_200_000_000) == "1.2 GB · 3 items")
    }
}
