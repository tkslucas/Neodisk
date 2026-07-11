import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The floating warnings panel: dedupe, dismissal, and the 100-row cap.
/// Regression: the lazy-filter version trapped in `prefix(_:)` because the
/// seen-ID dedupe made the predicate stateful ("Range requires
/// lowerBound <= upperBound" when opening a cached scan with warnings).
@MainActor
@Suite(.serialized) struct VisibleScanWarningsTests {
    @Test func testDeduplicatesDismissesAndCapsWarnings() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "VisibleScanWarningsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "VisibleScanWarningsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = NeodiskViewModel(
            snapshotCache: ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )

        // 150 unique warnings, each repeated twice (content-derived identity
        // collapses repeats), plus one that gets dismissed.
        let dismissed = ScanWarning(path: "/root/secret", message: "denied", category: .permissionDenied)
        var warnings: [ScanWarning] = [dismissed]
        for index in 0..<150 {
            let warning = ScanWarning(path: "/root/item-\(index)", message: "skipped", category: .fileSystem)
            warnings.append(warning)
            warnings.append(warning)
        }

        let file = makeTestFileNode(id: "/root/file", name: "file")
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        model.coordinator.restoreCompletedSnapshot(
            makeTestSnapshot(target: makeTestTarget("/root"), root: root, store: store, warnings: warnings)
        )
        model.dismissWarning(dismissed.id)

        let visible = model.visibleScanWarnings
        #expect(visible.count == 100)
        #expect(Set(visible.map(\.id)).count == 100)
        #expect(!visible.contains { $0.id == dismissed.id })
        #expect(visible.first?.path == "/root/item-0")
    }
}
