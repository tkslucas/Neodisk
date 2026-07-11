import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Drill-in from a kind row to the searchable file list.
@MainActor
@Suite(.serialized) struct KindFileListTests {
    @Test func testOpenFilterSelectAndCloseKindFileList() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "KindFileListTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "KindFileListTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = NeodiskViewModel(
            snapshotCache: ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )

        let movie = makeTestFileNode(id: "/kinds/movie.mp4", name: "movie.mp4", size: 3_000)
        let clip = makeTestFileNode(id: "/kinds/clip.mov", name: "Clip.mov", size: 2_000)
        let notes = makeTestFileNode(id: "/kinds/notes.txt", name: "notes.txt", size: 100)
        let children = [movie, clip, notes]
        let root = makeTestDirectoryNode(id: "/kinds", name: "kinds", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        model.coordinator.restoreCompletedSnapshot(
            makeTestSnapshot(target: makeTestTarget("/kinds"), root: root, store: store)
        )

        model.kinds.displayMode = .categories
        let videoStat = FileKindStat(
            kind: FileKind(id: "cat-video", displayName: "Videos"),
            totalAllocatedSize: 5_000,
            fileCount: 2,
            rgb: SIMD3(0, 0, 1)
        )
        model.kinds.openFileList(for: videoStat)
        try await waitUntil("kind file list built") { model.kinds.fileList != nil }

        // Unfiltered: every video, largest first.
        #expect(model.kinds.fileListVisibleIDs == [movie.id, clip.id])
        #expect(model.kinds.fileListTotalMatches == 2)

        // Case-insensitive fuzzy search, debounced.
        model.kinds.fileListFilterText = "CLIP"
        try await waitUntil("filtered results published") {
            model.kinds.fileListVisibleIDs == [clip.id]
        }
        #expect(model.kinds.fileListTotalMatches == 1)

        // Clearing restores the size-ordered browse view.
        model.kinds.fileListFilterText = ""
        try await waitUntil("browse view restored") {
            model.kinds.fileListVisibleIDs == [movie.id, clip.id]
        }

        // Selecting from the list reveals the row in the outline.
        model.select(clip.id)
        #expect(model.selectedNodeID == clip.id)
        #expect(model.expandedNodeIDs.contains(root.id))

        model.kinds.closeFileList()
        #expect(model.kinds.fileList == nil)
        #expect(model.kinds.fileListFilterText.isEmpty)
        #expect(model.kinds.fileListVisibleIDs.isEmpty)
    }

    @Test func testOutlineSearchFiltersWholeScanWithoutNavigating() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "OutlineSearchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "OutlineSearchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = NeodiskViewModel(
            snapshotCache: ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )

        let report = makeTestFileNode(id: "/scan/docs/report.pdf", name: "report.pdf", size: 500)
        let movie = makeTestFileNode(id: "/scan/movie.mp4", name: "movie.mp4", size: 9_000)
        let docs = makeTestDirectoryNode(id: "/scan/docs", name: "docs", children: [report])
        let children = [docs, movie]
        let root = makeTestDirectoryNode(id: "/scan", name: "scan", children: children)
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: children,
            docs.id: [report],
        ])
        model.coordinator.restoreCompletedSnapshot(
            makeTestSnapshot(target: makeTestTarget("/scan"), root: root, store: store)
        )
        model.zoomRootID = docs.id

        model.search.text = "report"
        try await waitUntil("search results published") {
            model.search.results != nil
        }

        let results = try #require(model.search.results)
        #expect(results.ids == [report.id])
        #expect(results.totalMatches == 1)
        // Search never navigates: zoom (and with it the treemap) stays put.
        #expect(model.zoomRootID == docs.id)

        // Selecting a result is a normal selection with ancestor reveal.
        model.select(report.id)
        #expect(model.selectedNodeID == report.id)
        #expect(model.expandedNodeIDs.contains(docs.id))

        model.search.clear()
        try await waitUntil("outline restored") {
            model.search.results == nil
        }
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
