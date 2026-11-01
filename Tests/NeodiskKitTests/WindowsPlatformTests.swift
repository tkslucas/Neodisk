#if os(Windows)
import Foundation
import Testing
import WinSDK
@testable import NeodiskKit

/// The Windows reader against the system's own per-file answers, and the cases only Windows has: reparse points,
/// the hidden attribute, ACL-denied folders, long paths.
@Suite struct WindowsPlatformTests {
    private func makeDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "neodisk-windows-\(Foundation.UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readChildren(of url: URL) throws -> [String: BulkDirectoryChild] {
        var children: [String: BulkDirectoryChild] = [:]
        _ = try BulkDirectoryReader.readChildren(
            ofDirectory: url,
            using: BulkDirectoryReader.Context(),
            cancellationCheck: {}
        ) { children[$0.name] = $0 }
        return children
    }

    private func handleInfo(_ path: String) -> WindowsFileInfo.HandleInfo? {
        guard let handle = WindowsFileInfo.open(path: path, access: DWORD(FILE_READ_ATTRIBUTES)) else { return nil }
        defer { CloseHandle(handle) }
        return WindowsFileInfo.HandleInfo(handle)
    }

    private func scan(_ root: URL) async throws -> ScanSnapshot {
        var finished: ScanSnapshot?
        for try await event in ScanEngine().scan(target: ScanTarget(url: root), options: ScanOptions()) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        return try #require(finished)
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// An elevated shell (an SSH session, an admin CI runner) can hold the backup privilege enabled, which reads
    /// through any ACL. Dropped while `body` runs so a deny applies, as it does for the app.
    private func withoutBackupPrivilege<Result>(_ body: () async throws -> Result) async throws -> Result {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY), &token),
              let token else { return try await body() }
        defer { CloseHandle(token) }
        var luid = LUID()
        guard "SeBackupPrivilege".withCString(encodedAs: UTF16.self, { LookupPrivilegeValueW(nil, $0, &luid) }) else {
            return try await body()
        }
        var disabled = TOKEN_PRIVILEGES(PrivilegeCount: 1, Privileges: LUID_AND_ATTRIBUTES(Luid: luid, Attributes: 0))
        var previous = TOKEN_PRIVILEGES()
        var previousLength = DWORD(MemoryLayout<TOKEN_PRIVILEGES>.size)
        guard AdjustTokenPrivileges(
            token, false, &disabled, DWORD(MemoryLayout<TOKEN_PRIVILEGES>.size), &previous, &previousLength
        ) else { return try await body() }
        defer { _ = AdjustTokenPrivileges(token, false, &previous, 0, nil, nil) }
        return try await body()
    }

    private var systemRoot: String { ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows" }

    @Test func bulkEntriesMatchHandleQueriesAcrossARealDirectory() throws {
        // A real system directory: thousands of DLLs, subfolders, some entries a user can't open.
        let root = URL(filePath: systemRoot + "\\System32", directoryHint: .isDirectory)
        let children = try readChildren(of: root)
        #expect(children.count > 100)

        var compared = 0
        for child in children.values.prefix(400) {
            let metadata = try #require(child.metadata)
            guard let info = handleInfo(root.appending(path: child.name).path) else { continue }
            compared += 1
            let isDirectory = info.attributes & UInt32(FILE_ATTRIBUTE_DIRECTORY) != 0
            #expect(child.deviceID == info.volumeSerial, "\(child.name)")
            if metadata.isSymbolicLink { continue }
            #expect(metadata.isDirectory == isDirectory, "\(child.name)")
            if metadata.isDirectory {
                #expect(metadata.allocatedSize == 0 && metadata.logicalSize == 0)
                #expect(metadata.fileIdentity == .fileSystem(device: info.volumeSerial, inode: info.fileID))
            } else {
                #expect(metadata.logicalSize == info.endOfFile, "\(child.name)")
                #expect(metadata.allocatedSize == info.allocationSize, "\(child.name)")
                #expect(metadata.linkCount == 1, "\(child.name)")
            }
        }
        #expect(compared > 100)
    }

    @Test func sizesAreTheFileLengthAndItsClusters() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 3, count: 10_000).write(to: root.appending(path: "ten-thousand.bin"))
        var sectorsPerCluster: DWORD = 0, bytesPerSector: DWORD = 0, freeClusters: DWORD = 0, totalClusters: DWORD = 0
        let volumeRoot = try #require(WindowsVolume.root(for: root.path))
        let gotClusterSize = volumeRoot.withCString(encodedAs: UTF16.self) {
            GetDiskFreeSpaceW($0, &sectorsPerCluster, &bytesPerSector, &freeClusters, &totalClusters)
        }
        #expect(gotClusterSize)
        let clusterSize = Int64(sectorsPerCluster) * Int64(bytesPerSector)

        let metadata = try #require(try readChildren(of: root)["ten-thousand.bin"]?.metadata)
        #expect(metadata.logicalSize == 10_000)
        #expect(metadata.allocatedSize == (10_000 + clusterSize - 1) / clusterSize * clusterSize)
        #expect(!metadata.isDirectory && !metadata.isSymbolicLink && !metadata.isDataless)
    }

    @Test func hiddenFollowsTheAttributeNotADotName() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appending(path: ".dotfile"))
        let secret = root.appending(path: "secret")
        try Data("b".utf8).write(to: secret)
        let hid = WindowsPath.withWidePath(secret.path) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_HIDDEN)) }
        #expect(hid)

        let children = try readChildren(of: root)
        #expect(Set(children.keys) == [".dotfile", "secret"])
        #expect(children[".dotfile"]?.isHidden == false)
        #expect(children["secret"]?.isHidden == true)
    }

    /// Symbolic links and junctions are leaves: their targets are counted where they are, never through them.
    @Test func reparsePointsAreLeavesNeverFollowed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: target.appending(path: "big.bin"))

        let symlink = root.appending(path: "symlink")
        let flags = DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)
        let linked = WindowsPath.withWidePath(symlink.path) { link in
            WindowsPath.withWidePath(target.path) { CreateSymbolicLinkW(link, $0, flags) }
        }
        try #require(linked != 0, "creating a symbolic link needs Developer Mode or an elevated process")
        let junction = root.appending(path: "junction")
        let comspec = ProcessInfo.processInfo.environment["ComSpec"] ?? systemRoot + "\\System32\\cmd.exe"
        try #require(try run(comspec, ["/c", "mklink", "/J", WindowsPath.native(junction.path), WindowsPath.native(target.path)]) == 0)

        let children = try readChildren(of: root)
        for name in ["symlink", "junction"] {
            let metadata = try #require(children[name]?.metadata, "\(name)")
            #expect(metadata.isSymbolicLink, "\(name)")
            #expect(!metadata.isDirectory, "\(name)")
            #expect(metadata.allocatedSize == 0 && metadata.logicalSize == 0, "\(name)")
        }
        // Even listed directly, a junction shows its own (empty) contents, not its target's.
        #expect(try readChildren(of: junction).isEmpty)

        let snapshot = try await scan(root)
        #expect(snapshot.aggregateStats.totalLogicalSize == 1_000_000)
        #expect(snapshot.treeStore.children(of: symlink.path).isEmpty)
        #expect(snapshot.treeStore.children(of: junction.path).isEmpty)
    }

    /// A folder whose ACL denies listing becomes an inaccessible node with a permission warning.
    @Test func aFolderDeniedByItsACLIsAWarningNotAFailure() async throws {
        let root = try makeDirectory()
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 5_000).write(to: locked.appending(path: "inside.bin"))
        try Data(count: 7_000).write(to: root.appending(path: "outside.bin"))
        let icacls = systemRoot + "\\System32\\icacls.exe"
        let lockedPath = WindowsPath.native(locked.path)
        defer {
            _ = try? run(icacls, [lockedPath, "/remove:d", "*S-1-1-0"])
            try? FileManager.default.removeItem(at: root)
        }
        // Everyone: no listing.
        try #require(try run(icacls, [lockedPath, "/deny", "*S-1-1-0:(RD)"]) == 0)

        let snapshot = try await withoutBackupPrivilege { try await scan(root) }
        let node = try #require(snapshot.treeStore.node(id: locked.path))
        #expect(!node.isSelfAccessible)
        #expect(snapshot.treeStore.children(of: locked.path).isEmpty)
        let warning = try #require(snapshot.scanWarnings.first { $0.path == locked.path })
        #expect(warning.category == .permissionDenied)
        #expect(snapshot.aggregateStats.totalLogicalSize == 7_000)
    }

    @Test func metadataLoaderAgreesWithTheBulkReader() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 70_000).write(to: root.appending(path: "blob"))
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: false)

        let loader = ScanMetadataLoader()
        for (name, bulk) in try readChildren(of: root) {
            let bulkMetadata = try #require(bulk.metadata)
            let loaded = try loader.metadata(for: root.appending(path: name))
            #expect(loaded.isDirectory == bulkMetadata.isDirectory, "\(name)")
            #expect(loaded.isSymbolicLink == bulkMetadata.isSymbolicLink, "\(name)")
            #expect(loaded.allocatedSize == bulkMetadata.allocatedSize, "\(name)")
            #expect(loaded.logicalSize == bulkMetadata.logicalSize, "\(name)")
            #expect(loaded.linkCount == bulkMetadata.linkCount, "\(name)")
            #expect(loaded.fileIdentity == bulkMetadata.fileIdentity, "\(name)")
            #expect(loaded.lastModified == bulkMetadata.lastModified, "\(name)")
        }
    }

    /// The trash checks re-read an item by the identity the scan recorded; both must agree.
    @Test func aScannedItemStillVerifiesAsItself() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: folder.appending(path: "large.bin"))

        let snapshot = try await scan(root)
        for path in [folder.path, folder.appending(path: "large.bin").path] {
            let node = try #require(snapshot.treeStore.node(id: path))
            #expect(node.fileIdentity != nil, "\(path)")
            #expect(TrashMover.verify(node) == nil, "\(path)")
        }
        try FileManager.default.removeItem(at: folder.appending(path: "large.bin"))
        let gone = try #require(snapshot.treeStore.node(id: folder.appending(path: "large.bin").path))
        #expect(TrashMover.verify(gone) == .missing)
    }

    /// Past MAX_PATH the reader opens through the `\\?\` prefix.
    @Test func deepTreesPastMaxPathAreRead() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var deep = root
        for index in 0..<12 {
            deep = deep.appending(path: "segment-\(index)-" + String(repeating: "x", count: 20), directoryHint: .isDirectory)
        }
        #expect(deep.path.utf16.count > 300)
        try #require(createDirectories(deep.path))
        let file = deep.appending(path: "leaf.bin")
        let wrote = WindowsPath.withWidePath(file.path) { path -> Bool in
            let handle = CreateFileW(path, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            guard let handle, handle != HANDLE(bitPattern: -1) else { return false }
            defer { CloseHandle(handle) }
            var bytes = [UInt8](repeating: 9, count: 4_321)
            var written: DWORD = 0
            return WriteFile(handle, &bytes, DWORD(bytes.count), &written, nil) && written == 4_321
        }
        try #require(wrote)

        let snapshot = try await scan(root)
        #expect(snapshot.aggregateStats.totalLogicalSize == 4_321)
        #expect(snapshot.treeStore.node(id: file.path)?.logicalSize == 4_321)
    }

    private func createDirectories(_ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            prefix += prefix.isEmpty ? String(component) : "/" + component
            guard prefix.utf16.count > 3 else { continue }
            let made = WindowsPath.withWidePath(prefix) { CreateDirectoryW($0, nil) }
            if !made, GetLastError() != DWORD(ERROR_ALREADY_EXISTS) { return false }
        }
        return true
    }

    @Test func driveRootsAreScanTargetsAndJoinWithoutADoubleSlash() throws {
        let systemDrive = ProcessInfo.processInfo.environment["SystemDrive"] ?? "C:"
        for spelling in [systemDrive + "\\", systemDrive + "/", systemDrive + "\\.", systemDrive + "\\Windows\\.."] {
            let target = ScanTarget(url: URL(filePath: spelling, directoryHint: .isDirectory))
            #expect(target.id == systemDrive + "/", "\(spelling)")
            #expect(target.kind == .volume, "\(spelling)")
        }
        let windowsTarget = ScanTarget(url: URL(filePath: systemRoot + "\\System32\\.."))
        #expect(windowsTarget.id.caseInsensitiveCompare(WindowsPath.lexicallyStandardized(systemRoot)) == .orderedSame)
        #expect(ScanEngine.nodeChildPath(parentPath: systemDrive + "/", childName: "Windows") == systemDrive + "/Windows")
        #expect(WindowsPath.lexicallyStandardized("C:\\a\\..\\..\\b\\.\\c\\") == "C:/b/c")
        #expect(WindowsPath.lexicallyStandardized("//server/share/../x") == "//server/share/x")
        let rootChildren = try readChildren(of: URL(filePath: systemDrive + "/", directoryHint: .isDirectory))
        #expect(rootChildren.keys.contains { $0.caseInsensitiveCompare("Windows") == .orderedSame })
        #expect(try ScanMetadataLoader().metadata(for: URL(filePath: systemDrive + "/")).isDirectory)
    }

    @Test func missingItemsThrowNotFound() {
        let loader = ScanMetadataLoader()
        do {
            _ = try loader.metadata(for: URL(filePath: NSTemporaryDirectory()).appending(path: "missing-\(Foundation.UUID().uuidString)"))
            Issue.record("expected an error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
        }
    }

    @Test func volumeFiguresComeFromTheDrive() throws {
        let info = try #require(VolumeSpaceInfo.load(for: URL(filePath: NSTemporaryDirectory())))
        #expect(info.totalCapacity > 0)
        #expect(info.usedBytes > 0 && info.usedBytes < info.totalCapacity)
        let volumeRoot = try #require(WindowsVolume.root(for: NSTemporaryDirectory()))
        #expect(WindowsVolume.information(root: volumeRoot)?.fileSystemName == "ntfs")
        #expect(ScanSourceProfile.detect(for: URL(filePath: NSTemporaryDirectory())) != .unsupported)
    }
}
#endif
