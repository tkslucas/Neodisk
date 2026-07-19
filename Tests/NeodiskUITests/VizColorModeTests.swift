import Foundation
import Testing
import NeodiskKit
import TreemapKit
@testable import NeodiskUI

/// The shared visualization color mode: branch hues whenever no kind/age
/// legend is on screen (Largest tab or hidden statistics panel), for every
/// visualization and treemap style alike.
@MainActor
@Suite struct VizColorModeTests {
    @Test func branchModeIsStyleAgnostic() async throws {
        let suiteName = "VizColorModeTests-\(UUID().uuidString)"
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { removeTestDefaultsSuite(defaults, named: suiteName) }
        let model = NeodiskViewModel(
            snapshotCache: ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )

        let movie = makeTestFileNode(id: "/scan/movie.mp4", name: "movie.mp4", size: 3_000)
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: [movie])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [movie]])
        model.coordinator.restoreCompletedSnapshot(
            makeTestSnapshot(target: makeTestTarget("/scan"), root: root, store: store)
        )

        // Largest tab: branch mode regardless of treemap style.
        model.analysisTab = .largest
        for style in [TreemapStyle.cushion, .flat] {
            model.treemapStyle = style
            #expect(model.vizColorMode == .branch)
            #expect(model.vizHighlight == nil)
        }

        // A legend tab with the panel visible keeps kind colors, and an
        // active kind drill-in reaches the map as a highlight.
        model.analysisTab = .kinds
        model.treemapStyle = .cushion
        #expect(model.vizColorMode == .kind)
        model.kinds.displayMode = .categories
        let videoStat = FileKindStat(
            kind: FileKind(id: "cat-video", displayName: "Videos"),
            totalAllocatedSize: 3_000,
            fileCount: 1,
            rgb: SIMD3(0, 0, 1)
        )
        model.kinds.openFileList(for: videoStat)
        try await waitUntil("kind file list built") { model.kinds.drill.context != nil }
        #expect(model.vizHighlight == .kind("cat-video"))

        // Hiding the panel reverts to branch and drops the highlight;
        // reopening restores the tab's lens.
        model.showKindStats = false
        #expect(model.vizColorMode == .branch)
        #expect(model.vizHighlight == nil)
        model.showKindStats = true
        #expect(model.vizColorMode == .kind)
        #expect(model.vizHighlight == .kind("cat-video"))
    }
}
