import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// The notice strip's warning model: dedupe, the Full Disk Access filter,
/// popover grouping, and the advisor-gated Full Disk Access suggestion.
@MainActor
@Suite(.serialized) struct VisibleScanWarningsTests {
    private func makeModel(cacheDirectory: URL, defaults: UserDefaults) -> NeodiskViewModel {
        NeodiskViewModel(
            snapshotCache: ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )
    }

    private func restore(_ model: NeodiskViewModel, warnings: [ScanWarning]) {
        let file = makeTestFileNode(id: "/root/file", name: "file")
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        model.coordinator.restoreCompletedSnapshot(
            makeTestSnapshot(target: makeTestTarget("/root"), root: root, store: store, warnings: warnings)
        )
    }

    @Test func testDeduplicatesWarnings() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "VisibleScanWarningsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "VisibleScanWarningsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = makeModel(cacheDirectory: cacheDirectory, defaults: defaults)

        // 150 unique warnings, each repeated twice: content-derived identity
        // collapses repeats.
        var warnings: [ScanWarning] = []
        for index in 0..<150 {
            let warning = ScanWarning(path: "/root/item-\(index)", message: "skipped", category: .fileSystem)
            warnings.append(warning)
            warnings.append(warning)
        }
        restore(model, warnings: warnings)

        let visible = model.warnings.visible
        #expect(visible.count == 150)
        #expect(Set(visible.map(\.id)).count == 150)
        #expect(visible.first?.path == "/root/item-0")
    }

    @Test func testFullDiskAccessHidesPermissionDeniedWarnings() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "VisibleScanWarningsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "VisibleScanWarningsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = makeModel(cacheDirectory: cacheDirectory, defaults: defaults)

        let denied = ScanWarning(path: "/root/protected", message: "denied", category: .permissionDenied)
        let ioError = ScanWarning(path: "/root/broken", message: "I/O error", category: .fileSystem)
        restore(model, warnings: [denied, ioError])

        // Without a Full Disk Access verdict, every warning shows.
        #expect(model.warnings.fullDiskAccessStatus == .unknown)
        #expect(model.warnings.visible.map(\.id) == [denied.id, ioError.id])

        // Granted: the remaining permission-denied warnings are dead ends no
        // grant can fix, so they hide; genuine filesystem errors stay.
        model.warnings.fullDiskAccessStatus = .granted
        #expect(model.warnings.visible.map(\.id) == [ioError.id])

        model.warnings.fullDiskAccessStatus = .notGranted
        #expect(model.warnings.visible.map(\.id) == [denied.id, ioError.id])
    }

    @Test func testGroupsWarningsOnShallowAncestors() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "VisibleScanWarningsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "VisibleScanWarningsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = makeModel(cacheDirectory: cacheDirectory, defaults: defaults)

        restore(model, warnings: [
            ScanWarning(path: "/private/var/folders/xy/one", message: "denied", category: .permissionDenied),
            ScanWarning(path: "/private/var/folders/zz/two", message: "denied", category: .permissionDenied),
            ScanWarning(path: "/private/var/folders/zz/three", message: "I/O error", category: .fileSystem),
            ScanWarning(path: "/Volumes/Backup/lonely", message: "denied", category: .permissionDenied),
        ])

        let groups = model.warnings.groups
        #expect(groups.map(\.path) == ["/private/var/folders", "/Volumes/Backup/lonely"])
        #expect(groups.map(\.count) == [3, 1])
        // Mixed categories fall back to the generic warning icon; a lone
        // warning keeps its full path as the row.
        #expect(groups[0].isPermissionDenied == false)
        #expect(groups[1].isPermissionDenied == true)
        #expect(groups[0].details.count == 3)
    }

    @Test func testGroupAncestorDepths() {
        let home = NSHomeDirectory()
        #expect(ScanWarningsModel.groupAncestor(of: home + "/Library/Mail/V10/box") == home + "/Library/Mail")
        #expect(ScanWarningsModel.groupAncestor(of: home + "/Library") == home + "/Library")
        #expect(ScanWarningsModel.groupAncestor(of: "/private/var/folders/xy/T") == "/private/var/folders")
        #expect(ScanWarningsModel.groupAncestor(of: "/Volumes") == "/Volumes")
    }

    @Test func testSuggestsFullDiskAccessOnlyWhenGrantWouldHelp() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "VisibleScanWarningsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let defaultsSuiteName = "VisibleScanWarningsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { removeTestDefaultsSuite(defaults, named: defaultsSuiteName) }
        let model = makeModel(cacheDirectory: cacheDirectory, defaults: defaults)
        model.warnings.fullDiskAccessStatus = .notGranted

        // A path Full Disk Access cannot unlock: no suggestion.
        restore(model, warnings: [
            ScanWarning(path: "/Library/Caches/com.apple.iconservices.store", message: "denied", category: .permissionDenied)
        ])
        #expect(model.warnings.suggestFullDiskAccess == false)

        // A path the grant actually unlocks: suggest — unless already granted.
        restore(model, warnings: [
            ScanWarning(path: NSHomeDirectory() + "/Library/Mail/V10", message: "denied", category: .permissionDenied)
        ])
        #expect(model.warnings.suggestFullDiskAccess == true)
        model.warnings.fullDiskAccessStatus = .granted
        #expect(model.warnings.suggestFullDiskAccess == false)
    }
}
