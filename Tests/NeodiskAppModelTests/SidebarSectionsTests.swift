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

    /// Cleanup's visibility is the Trash preference, never a stored flag.
    @Test func cleanupIsShownExactlyWhenEnabled() {
        var state = SidebarSectionState(hidden: "cleanup")
        state.setShown(.cleanup, false)
        #expect(state.hidden.isEmpty)
        #expect(state.isShown(.cleanup, cleanupEnabled: true))
        #expect(!state.isShown(.cleanup, cleanupEnabled: false))
        #expect(state.isShown(.volumes, cleanupEnabled: false))
    }

    @Test func revealShowsAndExpands() {
        var state = SidebarSectionState(hidden: "folders", collapsed: "folders,cleanup")
        state.reveal(.folders)
        state.reveal(.cleanup)
        #expect(state.isShown(.folders, cleanupEnabled: true))
        #expect(state.isExpanded(.folders) && state.isExpanded(.cleanup))
    }

    @Test func rowSizeIsFreeSpaceForVolumesAndScannedSizeForFolders() throws {
        let space = try #require(VolumeSpaceInfo.make(
            totalCapacity: 2_000_000_000_000,
            availableCapacity: 512_000_000_000,
            availableCapacityForImportantUsage: 640_000_000_000
        ))
        // Finder-style available: purgeable counts.
        #expect(SidebarRowText.size(space: space, scannedBytes: nil) == "640 GB free")
        #expect(SidebarRowText.size(space: nil, scannedBytes: 1_500_000) == "1.5 MB")
        #expect(SidebarRowText.size(space: nil, scannedBytes: nil) == nil)
        #expect(SidebarRowText.tooltip(path: "/", space: space) == "/\n640 GB free of 2 TB")
        #expect(SidebarRowText.tooltip(path: "/Users/me", space: nil) == "/Users/me")
        #expect(SidebarRowText.scanned(nil) == nil)
    }

    @Test func cleanupSummaryCountsItems() {
        #expect(CleanupText.summary(count: 0, totalSize: 0) == nil)
        #expect(CleanupText.summary(count: 1, totalSize: 8_000) == "8 KB · 1 item")
        #expect(CleanupText.summary(count: 3, totalSize: 1_200_000_000) == "1.2 GB · 3 items")
    }
}
