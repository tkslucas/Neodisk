#if os(Windows)
import Foundation
import Testing
import WinSDK
@testable import NeodiskKit

/// The tests need a Recycle Bin on the temp folder's drive, as on a desktop or a CI runner's fixed disk.
private func tempDriveHasRecycleBin() -> Bool {
    let temp = FileManager.default.temporaryDirectory.path
    guard let root = WindowsVolume.root(for: temp),
          WindowsVolume.driveType(root: root) == UINT(DRIVE_FIXED) else { return false }
    var info = SHQUERYRBINFO()
    info.cbSize = DWORD(MemoryLayout<SHQUERYRBINFO>.size)
    guard root.withCString(encodedAs: UTF16.self, { SHQueryRecycleBinW($0, &info) }) == S_OK else { return false }
    return WindowsRecycleBin.readSettings(volumeRoot: root) != nil
}

/// Moves real temp files to the Recycle Bin of the temp folder's drive, then removes exactly the entries they
/// made there. Never empties the bin and never changes its settings: size limits are injected.
@Suite(.serialized, .enabled(if: tempDriveHasRecycleBin()))
struct RecycleBinTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "neodisk-recycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scan(_ root: URL) async throws -> ScanSnapshot {
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        return try #require(finished)
    }

    /// Removes one entry this test put in the bin: the moved item (`$R…`) and the record beside it (`$I…`).
    private func removeFromRecycleBin(_ location: URL?) throws {
        let location = try #require(location)
        let name = location.lastPathComponent
        let folder = location.deletingLastPathComponent()
        #expect(location.path.lowercased().contains("$recycle.bin"), "\(location.path)")
        #expect(name.hasPrefix("$R"), "\(name)")
        guard location.path.lowercased().contains("$recycle.bin"), name.hasPrefix("$R") else { return }
        try FileManager.default.removeItem(at: location)
        try? FileManager.default.removeItem(at: folder.appending(path: "$I" + name.dropFirst(2)))
    }

    private func tiny(_ maxItemBytes: Int64, removesImmediately: Bool = false) -> WindowsRecycleBin {
        WindowsRecycleBin { _ in RecycleBinSettings(removesImmediately: removesImmediately, maxItemBytes: maxItemBytes) }
    }

    @Test func aScannedFileGoesToTheRecycleBinAndLeavesItsFolder() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "old.log")
        try Data(count: 1_000).write(to: file)
        let snapshot = try await scan(root)
        let node = try #require(snapshot.treeStore.node(id: file.path))

        let result = TrashMover(policy: .live()).move(node, scanRootID: snapshot.root.id)
        guard case .success(let location) = result else {
            Issue.record("expected a move, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let landed = try #require(location)
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(try Data(contentsOf: landed).count == 1_000)
        try removeFromRecycleBin(location)
    }

    @Test func aFolderGoesWholeWhenItFits() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Folder/Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 600).write(to: folder.appending(path: "a.bin"))
        try Data(count: 400).write(to: root.appending(path: "Folder/b.bin"))

        // Exactly the maximum fits: the shell's limit is inclusive.
        let location = try tiny(1_000).recycle(root.appending(path: "Folder"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Folder").path))
        let landed = try #require(location)
        #expect(FileManager.default.fileExists(atPath: landed.appending(path: "Nested/a.bin").path))
        try removeFromRecycleBin(location)
    }

    /// The shell would delete these permanently, so they're refused before it sees them, and stay.
    @Test func whatTheRecycleBinCantHoldIsRefusedAndStays() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "big.bin")
        try Data(count: 1_001).write(to: file)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(count: 400).write(to: folder.appending(path: "\(index).bin"))
        }
        #expect(throws: RecycleBinRefusal.tooLarge) { try tiny(1_000).recycle(file) }
        #expect(throws: RecycleBinRefusal.tooLarge) { try tiny(1_000).recycle(folder) }
        #expect(throws: RecycleBinRefusal.removesImmediately) {
            try tiny(1_000_000, removesImmediately: true).recycle(file)
        }
        for item in [file, folder] {
            #expect(FileManager.default.fileExists(atPath: item.path), "\(item.path)")
        }
    }

    @Test func aFolderHoldingAPathTooLongForTheRecycleBinIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        let padding = max(1, WindowsRecycleBin.pathLengthLimit - folder.path.utf16.count)
        let deep = folder.appending(path: String(repeating: "d", count: min(padding, 200)), directoryHint: .isDirectory)
            .appending(path: String(repeating: "e", count: 60), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 10).write(to: deep.appending(path: "note.txt"))

        #expect(throws: RecycleBinRefusal.pathTooLong) { try WindowsRecycleBin.live.recycle(folder) }
        #expect(FileManager.default.fileExists(atPath: deep.appending(path: "note.txt").path))
    }

    /// Refusals reach the caller as one item's failure, with the reason, like any other platform's.
    @Test func aRefusalIsThatItemsFailureAndTheItemStays() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "big.bin")
        try Data(count: 2_000).write(to: file)
        let snapshot = try await scan(root)
        let node = try #require(snapshot.treeStore.node(id: file.path))

        let bin = tiny(1_000)
        let mover = TrashMover(policy: .live()) { try bin.recycle($0) }
        let reason = try #require(RecycleBinRefusal.tooLarge.errorDescription)
        #expect(mover.move(node, scanRootID: snapshot.root.id) == .failure(.systemError(reason)))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The policy and the scanned identity are checked again right before the Recycle Bin is asked.
    @Test func protectedAndChangedItemsNeverReachTheRecycleBin() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "keep.txt")
        try Data(count: 10).write(to: file)
        let snapshot = try await scan(root)
        let node = try #require(snapshot.treeStore.node(id: file.path))

        let protecting = TrashMover(policy: TrashSafetyPolicy(protectedPaths: [file.path]))
        #expect(protecting.move(node, scanRootID: snapshot.root.id) == .failure(.refused(.protectedLocation)))
        #expect(protecting.move(node, scanRootID: node.id) == .failure(.refused(.scanRoot)))
        try Data(count: 99).write(to: file)
        #expect(TrashMover(policy: .live()).move(node, scanRootID: snapshot.root.id) == .failure(.changedSinceScan))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
