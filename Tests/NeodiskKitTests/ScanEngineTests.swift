import Testing
import Foundation
@testable import NeodiskKit

@Suite struct ScanEngineTests {
    @Test func testPackagesAreLeafNodesByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        #expect(packageNode.isPackage)
        #expect(packageNode.isDirectory)
        #expect(!(containsChildren(packageNode, in: snapshot)))
        #expect(packageNode.descendantFileCount == 1)
        #expect(packageNode.logicalSize >= Int64("binary".utf8.count))
        #expect(snapshot.aggregateStats.fileCount >= 1)
    }

    @Test func testPackageLeafNodesIncludeNestedPackageContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Host.app", directoryHint: .isDirectory)
        let nestedPackageURL = packageURL.appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
        let nestedBinaryURL = nestedPackageURL.appending(path: "Contents/MacOS/NestedBinary")

        try FileManager.default.createDirectory(at: nestedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: nestedBinaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Host.app" }))

        #expect(packageNode.descendantFileCount == 1)
        #expect(packageNode.logicalSize >= 2_048)
    }

    @Test func testPackageLeafSizesIgnoreNestedDirectoryEntries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Deep.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/Frameworks/A.framework/Resources/B.bundle/C.txt")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: 1_024).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Deep.app" }))

        #expect(packageNode.descendantFileCount == 1)
        #expect(packageNode.logicalSize == 1_024)
        #expect(packageNode.allocatedSize >= 1_024)
    }

    @Test func testPackageRootHardLinksOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Linked.app", directoryHint: .isDirectory)
        let originalURL = packageURL.appending(path: "Contents/Resources/original.bin")
        let linkedURL = packageURL.appending(path: "Contents/Resources/linked.bin")

        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xCA, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: packageURL),
            options: ScanOptions()
        )

        #expect(snapshot.root.descendantFileCount == 2)
        #expect(snapshot.root.logicalSize == 8_192)
        #expect(snapshot.root.allocatedSize > 0)
        #expect(snapshot.root.allocatedSize < snapshot.root.logicalSize)
        #expect(snapshot.aggregateStats.totalAllocatedSize == snapshot.root.allocatedSize)
    }

    @Test func testParallelPackageSummaryMatchesSerialSummary() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Parallel.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Parallel")
        let resourceURL = packageURL.appending(path: "Contents/Resources/Data/blob.dat")
        let hiddenURL = packageURL.appending(path: "Contents/Resources/.hidden")
        let nestedPackageBinaryURL = packageURL
            .appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Nested")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedPackageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: binaryURL)
        try Data(repeating: 0x2, count: 256).write(to: resourceURL)
        try Data(repeating: 0x3, count: 512).write(to: hiddenURL)
        try Data(repeating: 0x4, count: 1_024).write(to: nestedPackageBinaryURL)

        var serialOptions = ScanOptions()
        serialOptions.tuning.atomicSummaryWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.tuning.atomicSummaryWorkerLimit = 2

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)
        let serialPackageNode = try #require(rootChildren(in: serialSnapshot).first(where: { $0.name == "Parallel.app" }))
        let parallelPackageNode = try #require(rootChildren(in: parallelSnapshot).first(where: { $0.name == "Parallel.app" }))

        #expect(parallelPackageNode.descendantFileCount == serialPackageNode.descendantFileCount)
        #expect(parallelPackageNode.logicalSize == serialPackageNode.logicalSize)
        #expect(parallelPackageNode.allocatedSize == serialPackageNode.allocatedSize)
        #expect(parallelPackageNode.isAccessible == serialPackageNode.isAccessible)
        #expect(parallelPackageNode.isSelfAccessible == serialPackageNode.isSelfAccessible)
        #expect(parallelSnapshot.aggregateStats.fileCount == serialSnapshot.aggregateStats.fileCount)
        #expect(parallelSnapshot.aggregateStats.totalLogicalSize == serialSnapshot.aggregateStats.totalLogicalSize)
        #expect(parallelSnapshot.aggregateStats.totalAllocatedSize == serialSnapshot.aggregateStats.totalAllocatedSize)
    }

    @Test func testPackagesCanBeExpandedWhenEnabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Binary")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binaryURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(treatPackagesAsDirectories: true)
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        #expect(containsChildren(packageNode, in: snapshot))
        #expect(packageNode.descendantFileCount == 1)
    }

    /// "Show Package Contents": scanning a package as the root with
    /// `treatRootPackageAsDirectory` opens up that package only — bundles
    /// nested inside remain opaque leaves with aggregate sizes.
    @Test func testRootPackageExpandsWhileNestedPackagesStayOpaque() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Outer.app", directoryHint: .isDirectory)
        let binaryURL = packageURL.appending(path: "Contents/MacOS/Outer")
        let nestedBinaryURL = packageURL
            .appending(path: "Contents/PlugIns/Nested.appex", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Nested")

        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("outer".utf8).write(to: binaryURL)
        try Data("nested".utf8).write(to: nestedBinaryURL)

        // Without the option, a package target stays one opaque leaf.
        let opaqueSnapshot = try await finishedSnapshot(
            target: ScanTarget(url: packageURL),
            options: ScanOptions()
        )
        #expect(opaqueSnapshot.root.isPackage)
        #expect(!containsChildren(opaqueSnapshot.root, in: opaqueSnapshot))
        #expect(opaqueSnapshot.root.descendantFileCount == 2)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: packageURL),
            options: ScanOptions(treatRootPackageAsDirectory: true)
        )

        // The root package opened up and keeps its package identity.
        #expect(snapshot.root.isPackage)
        #expect(containsChildren(snapshot.root, in: snapshot))
        #expect(snapshot.root.allocatedSize >= opaqueSnapshot.root.allocatedSize)

        // The nested bundle inside is still an opaque leaf.
        let nested = try #require(
            snapshot.treeStore.allNodes.first(where: { $0.name == "Nested.appex" })
        )
        #expect(nested.isPackage)
        #expect(!containsChildren(nested, in: snapshot))
        #expect(nested.descendantFileCount == 1)
    }

    @Test func testAtomicPackageAccessFailuresProduceWarnings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Locked.app", directoryHint: .isDirectory)
        let readableFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let unreadableDirectoryURL = packageURL.appending(path: "Contents/Private")
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "Secret.dat")

        try FileManager.default.createDirectory(at: readableFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: readableFileURL)
        try Data("secret".utf8).write(to: unreadableFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDirectoryURL.path)
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Locked.app" }))

        #expect(!(packageNode.isAccessible))
        #expect(!(snapshot.scanWarnings.isEmpty))
        #expect(snapshot.scanWarnings.contains(where: { $0.path.contains("Locked.app") }))
    }

    @Test func testUnreadableOrdinaryDirectoryProducesWarningAndContinuesScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableFileURL = rootURL.appending(path: "visible.txt")
        let unreadableDirectoryURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)
        let unreadableFileURL = unreadableDirectoryURL.appending(path: "secret.txt")

        try Data("visible".utf8).write(to: readableFileURL)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: unreadableFileURL)
        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url.lastPathComponent == "Locked" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )
        let lockedNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let visibleNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let warning = try #require(snapshot.scanWarnings.first(where: { $0.path == lockedNode.url.path }))

        #expect(lockedNode.isDirectory)
        #expect(!(lockedNode.isPackage))
        #expect(!(lockedNode.isAccessible))
        #expect(lockedNode.allocatedSize == 0)
        #expect(lockedNode.logicalSize == 0)
        #expect(lockedNode.descendantFileCount == 0)
        #expect(!(containsChildren(lockedNode, in: snapshot)))
        #expect(visibleNode.isAccessible)
        #expect(warning.category == .permissionDenied)
        #expect(snapshot.aggregateStats.fileCount >= 1)
    }

    @Test func testLocalizedChildEnumerationFailureKeepsReadableSiblings() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let readableDirectoryURL = rootURL.appending(path: "Readable", directoryHint: .isDirectory)
        let readableFileURL = readableDirectoryURL.appending(path: "nested.txt")
        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let lockedURL = rootURL.appending(path: "Locked", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: readableDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockedURL, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: readableFileURL)
        try Data("visible".utf8).write(to: visibleFileURL)

        let permissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let engine = ScanEngine(enumeratedDirectoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return ScanEngine.DirectoryEnumerationResult(
                    urls: [readableDirectoryURL, visibleFileURL],
                    localizedFailures: [
                        ScanEngine.DirectoryEnumerationFailure(
                            url: lockedURL,
                            error: permissionError,
                            isDirectoryHint: true
                        )
                    ]
                )
            }

            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
            return ScanEngine.DirectoryEnumerationResult(urls: urls)
        })

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(),
            engine: engine
        )

        let rootChildNames = rootChildren(in: snapshot).map(\.name)
        let readableNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Readable" }))
        let visibleNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "visible.txt" }))
        let lockedNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Locked" }))
        let warning = try #require(snapshot.scanWarnings.first(where: { $0.path == lockedURL.path }))

        #expect(Set(rootChildNames) == Set(["Locked", "Readable", "visible.txt"]))
        #expect(children(of: readableNode, in: snapshot).map(\.name) == ["nested.txt"])
        #expect(visibleNode.isAccessible)
        #expect(lockedNode.isDirectory)
        #expect(!(lockedNode.isAccessible))
        #expect(!(containsChildren(lockedNode, in: snapshot)))
        #expect(warning.category == .permissionDenied)
        #expect(snapshot.root.descendantFileCount == 2)
    }

    @Test func testPackageLeafExcludesHiddenContentsWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let visibleFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let hiddenFileURL = packageURL.appending(path: "Contents/Resources/.secret")

        try FileManager.default.createDirectory(at: visibleFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 256).write(to: hiddenFileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions(includeHiddenFiles: false)
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        #expect(packageNode.descendantFileCount == 1)
        #expect(packageNode.logicalSize == 128)
        #expect(packageNode.allocatedSize >= 128)
    }

    @Test func testExcludesBasenameDirectoryLikeNodeModules() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let visibleFileURL = rootURL.appending(path: "visible.txt")
        let nodeModulesFileURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: "left-pad/index.js")

        try FileManager.default.createDirectory(at: nodeModulesFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 16).write(to: visibleFileURL)
        try Data(repeating: 0x2, count: 128).write(to: nodeModulesFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        #expect(rootChildren(in: snapshot).map(\.name) == ["visible.txt"])
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 16)
        #expect(snapshot.aggregateStats.fileCount == 1)
    }

    @Test func testExcludesFilesByGlob() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 32)
            .write(to: rootURL.appending(path: "notes.txt"))
        try Data(repeating: 0x2, count: 256)
            .write(to: rootURL.appending(path: "debug.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        #expect(rootChildren(in: snapshot).map(\.name) == ["notes.txt"])
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 32)
    }

    @Test func testExcludesDirectoryOnlyPatternsWithoutExcludingSameNamedFiles() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 256).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 32).write(to: rootURL.appending(path: "build"))

        var options = ScanOptions()
        options.exclusionPatterns = ["build/"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let nestedNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "nested" }))

        #expect(rootChildren(in: snapshot).map(\.name) == ["build", "nested"])
        #expect(children(of: nestedNode, in: snapshot).isEmpty)
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 32)
    }

    @Test func testExcludesPathGlobPatternsRelativeToScanRoot() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let libraryCacheFileURL = rootURL
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: "ignored.bin")
        let topLevelCacheFileURL = rootURL
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "kept.bin")

        try FileManager.default.createDirectory(at: libraryCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topLevelCacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: libraryCacheFileURL)
        try Data(repeating: 0x2, count: 64).write(to: topLevelCacheFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["Library/Caches/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let cachesNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Caches" }))
        let libraryNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        #expect(children(of: cachesNode, in: snapshot).map(\.name) == ["kept.bin"])
        #expect(children(of: libraryNode, in: snapshot).isEmpty)
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 64)
    }

    @Test func testExcludesDoubleStarPathGlobPatterns() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nestedBuildFileURL = rootURL
            .appending(path: "project/build", directoryHint: .isDirectory)
            .appending(path: "artifact.o")
        let keptFileURL = rootURL
            .appending(path: "project/Sources", directoryHint: .isDirectory)
            .appending(path: "main.swift")

        try FileManager.default.createDirectory(at: nestedBuildFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 512).write(to: nestedBuildFileURL)
        try Data(repeating: 0x2, count: 128).write(to: keptFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["**/build/**"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let projectNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "project" }))

        #expect(children(of: projectNode, in: snapshot).map(\.name) == ["Sources"])
        #expect(projectNode.descendantFileCount == 1)
        #expect(projectNode.logicalSize == 128)
    }

    @Test func testExcludesDSStoreEvenWhenHiddenFilesAreIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 24)
            .write(to: rootURL.appending(path: "visible.txt"))
        try Data(repeating: 0x2, count: 512)
            .write(to: rootURL.appending(path: ".DS_Store"))

        var options = ScanOptions(includeHiddenFiles: true)
        options.exclusionPatterns = [".DS_Store"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        #expect(rootChildren(in: snapshot).map(\.name) == ["visible.txt"])
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 24)
    }

    @Test func testSkipsCloudStorageFolderByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "GoogleDrive-example", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        #expect(rootChildren(in: snapshot).map(\.name).sorted() == ["Library", "local.txt"])
        #expect(children(of: libraryNode, in: snapshot).isEmpty)
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 64)
    }

    @Test func testCloudStorageFolderCanBeIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.includeCloudStorage = true
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let cloudStorageNode = try #require(children(of: libraryNode, in: snapshot).first(where: { $0.name == "CloudStorage" }))
        let providerNode = try #require(children(of: cloudStorageNode, in: snapshot).first(where: { $0.name == "Dropbox" }))

        #expect(children(of: providerNode, in: snapshot).map(\.name) == ["remote.bin"])
        #expect(snapshot.root.descendantFileCount == 2)
        #expect(snapshot.root.logicalSize == 576)
    }

    @Test func testSkipsICloudDriveFolderByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.iCloudDriveRootPath = iCloudDriveURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))

        #expect(rootChildren(in: snapshot).map(\.name).sorted() == ["Library", "local.txt"])
        #expect(children(of: libraryNode, in: snapshot).isEmpty)
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 64)
    }

    @Test func testICloudDriveFolderCanBeIncluded() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let localFileURL = rootURL.appending(path: "local.txt")
        let iCloudDriveURL = rootURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        let cloudFileURL = iCloudDriveURL
            .appending(path: "com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 64).write(to: localFileURL)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.includeCloudStorage = true
        options.iCloudDriveRootPath = iCloudDriveURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let libraryNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let iCloudDriveNode = try #require(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Mobile Documents" }))
        let providerNode = try #require(children(of: iCloudDriveNode, in: snapshot).first(where: { $0.name == "com~apple~CloudDocs" }))

        #expect(children(of: providerNode, in: snapshot).map(\.name) == ["remote.bin"])
        #expect(snapshot.root.descendantFileCount == 2)
        #expect(snapshot.root.logicalSize == 576)
    }

    @Test func testUsersCloudStorageWildcardIsSkippedByDefault() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage"
        )

        #expect(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage"), isDirectory: true))
        #expect(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"), isDirectory: false))
        #expect(!(matcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorageBackup"), isDirectory: true)))

        let explicitMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex/Library/CloudStorage",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage"
        )

        #expect(!(explicitMatcher.excludes(URL(filePath: "/Users/alex/Library/CloudStorage/Dropbox/file.bin"), isDirectory: false)))
    }

    @Test func testUsersICloudDriveWildcardIsSkippedByDefault() {
        let matcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: false,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        #expect(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents"), isDirectory: true))
        #expect(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false))
        #expect(!(matcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents Backup"), isDirectory: true)))

        let includingMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users",
            includeCloudStorage: true,
            cloudStorageRootPath: "/CustomHomes/colin/Library/CloudStorage",
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        #expect(!(includingMatcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false)))

        let explicitMatcher = ScanExclusionMatcher(
            patterns: [],
            rootPath: "/Users/alex/Library/Mobile Documents",
            includeCloudStorage: false,
            iCloudDriveRootPath: "/CustomHomes/colin/Library/Mobile Documents"
        )

        #expect(!(explicitMatcher.excludes(URL(filePath: "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/file.bin"), isDirectory: false)))
    }

    @Test func testExplicitCloudStorageFolderScanIsAllowedByDefault() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL
            .appending(path: "Dropbox", directoryHint: .isDirectory)
            .appending(path: "remote.bin")

        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: cloudStorageURL),
            options: options
        )

        #expect(rootChildren(in: snapshot).map(\.name) == ["Dropbox"])
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 512)
    }

    @Test func testVolumeScanWithExclusionsDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x1, count: 128)
            .write(to: rootURL.appending(path: "visible.txt"))

        var options = ScanOptions()
        options.exclusionPatterns = ["node_modules"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        #expect(!(rootChildren(in: snapshot).contains(where: { $0.isSynthetic })))
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.root.logicalSize == 128)
        #expect(snapshot.aggregateStats.totalAllocatedSize == snapshot.root.allocatedSize)
    }

    @Test func testVolumeScanWithCloudStorageExclusionDoesNotAddSystemUnattributedNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")

        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        var options = ScanOptions()
        options.cloudStorageRootPath = cloudStorageURL.path

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: options
        )

        #expect(!(rootChildren(in: snapshot).contains(where: { $0.isSynthetic })))
        #expect(snapshot.root.descendantFileCount == 1)
        #expect(snapshot.aggregateStats.totalAllocatedSize == snapshot.root.allocatedSize)
    }

    @Test func testExcludedFilesDoNotContributeToParentSizeTotals() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataURL = rootURL.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 10)
            .write(to: dataURL.appending(path: "keep.bin"))
        try Data(repeating: 0x2, count: 90)
            .write(to: dataURL.appending(path: "ignored.log"))

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let dataNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Data" }))

        #expect(children(of: dataNode, in: snapshot).map(\.name) == ["keep.bin"])
        #expect(dataNode.descendantFileCount == 1)
        #expect(dataNode.logicalSize == 10)
        #expect(snapshot.root.logicalSize == 10)
    }

    @Test func testExcludedFilesDoNotContributeThroughPackageSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let keptFileURL = packageURL.appending(path: "Contents/MacOS/Binary")
        let excludedFileURL = packageURL.appending(path: "Contents/Resources/debug.log")

        try FileManager.default.createDirectory(at: keptFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excludedFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 128).write(to: keptFileURL)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        #expect(packageNode.descendantFileCount == 1)
        #expect(packageNode.logicalSize == 128)
        #expect(snapshot.root.logicalSize == 128)
    }

    @Test func testExcludedPackageContentsStillEmitSummaryProgress() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL.appending(path: "Sample.app", directoryHint: .isDirectory)
        let excludedFileURL = packageURL.appending(path: "debug.log")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 2_048).write(to: excludedFileURL)

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]

        let engine = ScanEngine()
        var progressPaths: [String] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progressPaths.append(metrics.currentPath)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning, .partial:
                break
            }
        }

        let snapshot = try #require(finalSnapshot)
        let packageNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Sample.app" }))

        #expect(packageNode.descendantFileCount == 0)
        #expect(!(containsChildren(packageNode, in: snapshot)))
        #expect(progressPaths.contains(where: { $0.hasSuffix("/Sample.app/debug.log") }), "Expected package summary progress to include excluded file path")
    }

    @Test func testExcludedFilesDoNotContributeThroughAutoSummaries() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<10 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32)
                .write(to: shardURL.appending(path: "keep.tmp"))
            try Data(repeating: 0x7F, count: 4_096)
                .write(to: shardURL.appending(path: "ignored.log"))
        }

        var options = ScanOptions()
        options.exclusionPatterns = ["*.log"]
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        #expect(cacheNode.isAutoSummarized)
        #expect(cacheNode.descendantFileCount == 10)
        #expect(cacheNode.logicalSize == 10 * 32)
    }

    @Test func testCancellingScanStopsPackageLeafSummaryWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let packageContentsURL = rootURL
            .appending(path: "Large.app", directoryHint: .isDirectory)
            .appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageContentsURL, withIntermediateDirectories: true)

        for index in 0..<8_000 {
            let fileURL = packageContentsURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await scanTask.value

        #expect(!(didFinishCancelledScan))

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        #expect(followUpFinished)
    }

    @Test func testCancellingScanStopsWideDirectoryEnumerationWork() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        for index in 0..<10_000 {
            let fileURL = rootURL.appending(path: "payload-\(index).tmp")
            try Data([UInt8(index % 256)]).write(to: fileURL)
        }

        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let engine = ScanEngine()
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await Task.sleep(for: .milliseconds(10))
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(2)) {
            try await scanTask.value
        }

        #expect(!(didFinishCancelledScan))

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        #expect(followUpFinished)
    }

    @Test func testNewScanCanFinishWhilePreviousEnumerationIsStillCancelling() async throws {
        let rootURL = try makeTemporaryDirectory()
        let followUpURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: followUpURL)
        }

        let probe = BlockingDirectoryContentsProbe(blockedURL: rootURL)
        let engine = ScanEngine(directoryContents: { url, _, _, _ in
            try probe.contents(for: url)
        })
        let blockedScanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
            return didFinish
        }
        defer {
            probe.release()
            blockedScanTask.cancel()
        }

        try await probe.waitUntilBlocked()
        blockedScanTask.cancel()

        let followUpFinished = try await withTimeout(.seconds(1)) {
            for try await event in engine.scan(target: ScanTarget(url: followUpURL), options: ScanOptions()) {
                if case .finished = event {
                    return true
                }
            }
            return false
        }

        probe.release()
        let blockedScanFinished = await blockedScanTask.value

        #expect(followUpFinished)
        #expect(!(blockedScanFinished))
    }

    @Test func testEnumeratedDirectoryContentsChecksCancellationBeforeMaterializingAllURLs() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cancellation = DirectoryEnumerationCancellation()
        let enumerator = SlowDirectoryObjectEnumerator(rootURL: rootURL, totalCount: 10_000)
        let enumerationTask = Task {
            try ScanEngine.enumeratedDirectoryContents(
                url: rootURL,
                keys: nil,
                options: [],
                cancellationCheck: { try cancellation.check() },
                makeEnumerator: { _, _, _ in enumerator }
            )
        }

        try await enumerator.waitUntilProduced(64)
        cancellation.cancel()

        do {
            _ = try await withTimeout(.seconds(1)) {
                try await enumerationTask.value
            }
            Issue.record("Expected directory enumeration to stop after cancellation.")
        } catch is CancellationError {
            #expect(enumerator.producedCount < enumerator.totalCount)
        }
    }

    @Test func testCancellingScanStopsInjectedDirectoryEnumerationBeforeMaterialization() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let probe = CancellableDirectoryContentsProbe(totalCount: 10_000)
        let engine = ScanEngine(directoryContents: { url, _, _, cancellationCheck in
            guard url == rootURL else { return [] }
            return try probe.contents(for: url, cancellationCheck: cancellationCheck)
        })
        let scanTask = Task {
            var didFinish = false
            do {
                for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
                    if case .finished = event {
                        didFinish = true
                    }
                }
            } catch is CancellationError {
                return false
            }
            return didFinish
        }

        try await probe.waitUntilProduced(64)
        scanTask.cancel()
        let didFinishCancelledScan = try await withTimeout(.seconds(1)) {
            try await scanTask.value
        }

        #expect(!(didFinishCancelledScan))
        #expect(probe.producedCount < probe.totalCount)
    }

    @Test func testSymbolicLinksAreNotTraversed() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let nestedFile = realDirectory.appending(path: "payload.txt")
        let symlinkURL = rootURL.appending(path: "Alias")

        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nestedFile)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let aliasNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Alias" }))

        #expect(aliasNode.isSymbolicLink)
        #expect(!(containsChildren(aliasNode, in: snapshot)))
        #expect(aliasNode.itemKind == "Alias")
        #expect(aliasNode.descendantFileCount == 0)
        #expect(snapshot.aggregateStats.fileCount == 1)
    }

    @Test func testHardLinkedFilesOnlyCountAllocatedStorageOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalURL = rootURL.appending(path: "original.bin")
        let linkedURL = rootURL.appending(path: "linked.bin")

        try Data(repeating: 0xA5, count: 4_096).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: linkedURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )
        let children = rootChildren(in: snapshot)
        let allocatedSizes = children.map(\.allocatedSize)

        #expect(snapshot.aggregateStats.fileCount == 2)
        #expect(children.map(\.logicalSize).reduce(0, +) == 8_192)
        #expect(allocatedSizes.filter { $0 > 0 }.count == 1)
        #expect(snapshot.root.allocatedSize == allocatedSizes.reduce(0, +))
        #expect(children.allSatisfy { $0.fileIdentity != nil })
        #expect(children.map(\.linkCount) == [2, 2])
        #expect(children.filter { $0.allocatedSize == 0 }.map(\.unduplicatedAllocatedSize).count == 1)
        #expect(children.allSatisfy { $0.unduplicatedAllocatedSize > 0 })
    }

    @Test func testParallelTraversalAssignsHardLinkStorageDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alphaDirectoryURL = rootURL.appending(path: "Alpha", directoryHint: .isDirectory)
        let betaDirectoryURL = rootURL.appending(path: "Beta", directoryHint: .isDirectory)
        let alphaLinkURL = alphaDirectoryURL.appending(path: "linked.bin")
        let betaOriginalURL = betaDirectoryURL.appending(path: "original.bin")

        try FileManager.default.createDirectory(at: alphaDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0x4B, count: 4_096).write(to: betaOriginalURL)
        try FileManager.default.linkItem(at: betaOriginalURL, to: alphaLinkURL)

        let engine = ScanEngine(directoryContents: { url, keys, options, cancellationCheck in
            try cancellationCheck()
            if url == rootURL {
                return [alphaDirectoryURL, betaDirectoryURL]
            }
            if url == betaDirectoryURL {
                return [betaOriginalURL]
            }
            if url == alphaDirectoryURL {
                Thread.sleep(forTimeInterval: 0.04)
                try cancellationCheck()
                return [alphaLinkURL]
            }
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        })

        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        options.tuning.directoryTraversalWorkerLimit = 2
        options.tuning.directoryClassificationWorkerLimit = 1

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options,
            engine: engine
        )
        let alphaNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Alpha" }))
        let betaNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Beta" }))
        let alphaFile = try #require(children(of: alphaNode, in: snapshot).first)
        let betaFile = try #require(children(of: betaNode, in: snapshot).first)

        #expect(alphaFile.allocatedSize > 0)
        #expect(betaFile.allocatedSize == 0)
        #expect(alphaNode.allocatedSize == alphaFile.allocatedSize)
        #expect(betaNode.allocatedSize == 0)
        #expect(snapshot.root.allocatedSize == alphaFile.allocatedSize)
        #expect(snapshot.aggregateStats.totalAllocatedSize == snapshot.root.allocatedSize)
        #expect(snapshot.aggregateStats.fileCount == 2)
    }

    @Test func testScanTargetNormalizesSyntheticRootAliases() {
        let nofollowTarget = ScanTarget(url: URL(filePath: "/.nofollow/Users/example", directoryHint: .isDirectory))
        let resolveTarget = ScanTarget(url: URL(filePath: "/.resolve/System/Volumes/Data", directoryHint: .isDirectory))
        let rootAliasTarget = ScanTarget(url: URL(filePath: "/.nofollow", directoryHint: .isDirectory))

        #expect(nofollowTarget.url.path == "/Users/example")
        #expect(resolveTarget.url.path == "/System/Volumes/Data")
        #expect(rootAliasTarget.url.path == "/")
        #expect(rootAliasTarget.kind == .volume)
    }

    @Test func testScanTargetResolvesSymlinkRoots() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let realDirectory = rootURL.appending(path: "Real", directoryHint: .isDirectory)
        let symlinkURL = rootURL.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDirectory)

        let target = ScanTarget(url: symlinkURL)

        #expect(target.url.path == realDirectory.path)
        #expect(target.id == realDirectory.path)
    }

    @Test func testStartupVolumeScanExcludesSyntheticAndDuplicateNamespaces() {
        let startupBehavior = ScanEngine.ScanBehavior(excludesStartupVolumeInternals: true)
        let standardBehavior = ScanEngine.ScanBehavior.standard

        #expect(!(ScanEngine.includedChildURL(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )))
        #expect(!(ScanEngine.includedChildURL(
                URL(filePath: "/.nofollow", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )))
        #expect(!(ScanEngine.includedChildURL(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )))
        #expect(!(ScanEngine.includedChildURL(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )))
        #expect(!(ScanEngine.includedChildURL(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: startupBehavior
            )))
        #expect(!(ScanEngine.includedChildURL(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            )))
        #expect(ScanEngine.includedChildURL(
                URL(filePath: "/System/Library", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: startupBehavior
            ))
        #expect(ScanEngine.includedChildURL(
                URL(filePath: "/System/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/System", directoryHint: .isDirectory),
                behavior: standardBehavior
            ))
        #expect(ScanEngine.includedChildURL(
                URL(filePath: "/.file"),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            ))
        #expect(ScanEngine.includedChildURL(
                URL(filePath: "/dev", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            ))
        #expect(ScanEngine.includedChildURL(
                URL(filePath: "/.vol", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            ))
        #expect(ScanEngine.includedChildURL(
                URL(filePath: "/Volumes", directoryHint: .isDirectory),
                under: URL(filePath: "/", directoryHint: .isDirectory),
                behavior: standardBehavior
            ))
    }

    @Test func testVolumeSnapshotAddsNoSyntheticNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appending(path: "payload.bin")
        let cloudStorageURL = rootURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let cloudFileURL = cloudStorageURL.appending(path: "Dropbox/remote.bin")
        try Data(repeating: 0x5A, count: 1_024).write(to: fileURL)
        try FileManager.default.createDirectory(at: cloudFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: 512).write(to: cloudFileURL)

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "hfs" })
        let target = ScanTarget(url: rootURL, kind: .volume)
        var options = ScanOptions()
        options.includeCloudStorage = true
        options.cloudStorageRootPath = cloudStorageURL.path
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: target, options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let snapshot = try #require(finalSnapshot)

        // Volume snapshots carry only scanned bytes on every filesystem;
        // the gap up to used capacity is the UI's hidden space, never a
        // synthetic node.
        #expect(try !rootChildren(in: snapshot).contains(where: \.isSynthetic))
        #expect(snapshot.root.isAccessible)
        #expect(snapshot.aggregateStats.totalAllocatedSize == snapshot.root.allocatedSize)
    }

    @Test func testAPFSVolumeSnapshotKeepsScannedAllocatedTotal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data(repeating: 0x5A, count: 1_024).write(to: rootURL.appending(path: "payload.bin"))

        let engine = ScanEngine(volumeFileSystemTypeProvider: { _ in "apfs" })
        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL, kind: .volume),
            options: ScanOptions(),
            engine: engine
        )
        let children = rootChildren(in: snapshot)

        #expect(!(children.contains(where: { $0.isSynthetic })))
        #expect(snapshot.root.allocatedSize == children.reduce(0) { $0 + $1.allocatedSize })
        #expect(snapshot.aggregateStats.totalAllocatedSize == snapshot.root.allocatedSize)
    }

    @Test func testDirectoryChildrenAreOrderedDeterministically() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let alpha = rootURL.appending(path: "alpha.txt")
        let zeta = rootURL.appending(path: "zeta.txt")

        try Data(repeating: 0x41, count: 16).write(to: zeta)
        try Data(repeating: 0x42, count: 16).write(to: alpha)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        #expect(rootChildren(in: snapshot).map(\.name) == ["alpha.txt", "zeta.txt"])
    }

    @Test func testParallelDirectoryClassificationMatchesSerialClassification() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "file-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: (index % 7) + 1).write(to: fileURL)
        }

        for index in 0..<16 {
            let directoryURL = rootURL.appending(path: String(format: "folder-%03d", index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 9).write(to: directoryURL.appending(path: "payload.txt"))
        }

        try Data(repeating: 0xA, count: 64).write(to: rootURL.appending(path: "excluded.log"))

        var serialOptions = ScanOptions()
        serialOptions.exclusionPatterns = ["*.log"]
        serialOptions.tuning.directoryTraversalWorkerLimit = 1
        serialOptions.tuning.directoryClassificationWorkerLimit = 1
        var parallelOptions = ScanOptions()
        parallelOptions.exclusionPatterns = ["*.log"]
        parallelOptions.tuning.directoryTraversalWorkerLimit = 1
        parallelOptions.tuning.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        #expect(rootChildren(in: parallelSnapshot).map(\.name) == rootChildren(in: serialSnapshot).map(\.name))
        #expect(!(rootChildren(in: parallelSnapshot).contains(where: { $0.name == "excluded.log" })))
        #expect(parallelSnapshot.root.descendantFileCount == serialSnapshot.root.descendantFileCount)
        #expect(parallelSnapshot.root.logicalSize == serialSnapshot.root.logicalSize)
        #expect(parallelSnapshot.root.allocatedSize == serialSnapshot.root.allocatedSize)
        #expect(parallelSnapshot.aggregateStats.fileCount == serialSnapshot.aggregateStats.fileCount)
        #expect(parallelSnapshot.aggregateStats.directoryCount == serialSnapshot.aggregateStats.directoryCount)
    }

    @Test func testParallelDirectoryTraversalAndClassificationMatchSerialScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<180 {
            let fileURL = rootURL.appending(path: String(format: "root-%03d.dat", index))
            try Data(repeating: UInt8(index % 256), count: 8 + (index % 11)).write(to: fileURL)
        }

        for directoryIndex in 0..<8 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<160 {
                let fileURL = directoryURL.appending(path: String(format: "payload-%03d.bin", fileIndex))
                try Data(repeating: UInt8((directoryIndex + fileIndex) % 256), count: 4 + (fileIndex % 5)).write(to: fileURL)
            }

            try Data(repeating: 0xD, count: 32).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.tuning.directoryTraversalWorkerLimit = 1
        serialOptions.tuning.directoryClassificationWorkerLimit = 1
        serialOptions.tuning.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.tuning.directoryTraversalWorkerLimit = 4
        parallelOptions.tuning.directoryClassificationWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        #expect(rootChildren(in: parallelSnapshot).map(\.name) == rootChildren(in: serialSnapshot).map(\.name))
        #expect(parallelSnapshot.root.descendantFileCount == serialSnapshot.root.descendantFileCount)
        #expect(parallelSnapshot.root.logicalSize == serialSnapshot.root.logicalSize)
        #expect(parallelSnapshot.root.allocatedSize == serialSnapshot.root.allocatedSize)
        #expect(parallelSnapshot.aggregateStats.fileCount == serialSnapshot.aggregateStats.fileCount)
        #expect(parallelSnapshot.aggregateStats.directoryCount == serialSnapshot.aggregateStats.directoryCount)
        #expect(parallelSnapshot.aggregateStats.totalLogicalSize == serialSnapshot.aggregateStats.totalLogicalSize)
        #expect(parallelSnapshot.aggregateStats.totalAllocatedSize == serialSnapshot.aggregateStats.totalAllocatedSize)
        #expect(!(parallelSnapshot.treeStore.allNodes.contains { $0.id.hasSuffix("ignored.skip") }))

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try #require(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            #expect(children(of: parallelChild, in: parallelSnapshot).map(\.name) == children(of: serialChild, in: serialSnapshot).map(\.name))
        }
    }

    @Test func testParallelDirectoryTraversalMatchesSerialTraversal() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<12 {
            let directoryURL = rootURL.appending(path: String(format: "group-%02d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<6 {
                let fileURL = directoryURL.appending(path: String(format: "direct-%02d.dat", fileIndex))
                try Data(repeating: UInt8(directoryIndex + fileIndex), count: 32 + directoryIndex + fileIndex).write(to: fileURL)
            }

            for nestedIndex in 0..<4 {
                let nestedURL = directoryURL.appending(path: String(format: "nested-%02d", nestedIndex), directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

                for fileIndex in 0..<3 {
                    let fileURL = nestedURL.appending(path: String(format: "payload-%02d.bin", fileIndex))
                    try Data(repeating: UInt8(nestedIndex + fileIndex), count: 17 + nestedIndex + fileIndex).write(to: fileURL)
                }
            }

            try Data(repeating: 0xC, count: 128).write(to: directoryURL.appending(path: "ignored.skip"))
        }

        var serialOptions = ScanOptions()
        serialOptions.autoSummarizeDirectories = false
        serialOptions.exclusionPatterns = ["*.skip"]
        serialOptions.tuning.directoryTraversalWorkerLimit = 1
        serialOptions.tuning.directoryClassificationWorkerLimit = 1
        serialOptions.tuning.atomicSummaryWorkerLimit = 1

        var parallelOptions = serialOptions
        parallelOptions.tuning.directoryTraversalWorkerLimit = 4

        let serialSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: serialOptions)
        let parallelSnapshot = try await finishedSnapshot(target: ScanTarget(url: rootURL), options: parallelOptions)

        #expect(rootChildren(in: parallelSnapshot).map(\.name) == rootChildren(in: serialSnapshot).map(\.name))
        #expect(parallelSnapshot.root.descendantFileCount == serialSnapshot.root.descendantFileCount)
        #expect(parallelSnapshot.root.logicalSize == serialSnapshot.root.logicalSize)
        #expect(parallelSnapshot.root.allocatedSize == serialSnapshot.root.allocatedSize)
        #expect(parallelSnapshot.aggregateStats.fileCount == serialSnapshot.aggregateStats.fileCount)
        #expect(parallelSnapshot.aggregateStats.directoryCount == serialSnapshot.aggregateStats.directoryCount)
        #expect(parallelSnapshot.aggregateStats.totalLogicalSize == serialSnapshot.aggregateStats.totalLogicalSize)
        #expect(parallelSnapshot.aggregateStats.totalAllocatedSize == serialSnapshot.aggregateStats.totalAllocatedSize)

        for serialChild in rootChildren(in: serialSnapshot) {
            let parallelChild = try #require(rootChildren(in: parallelSnapshot).first { $0.id == serialChild.id })
            #expect(children(of: parallelChild, in: parallelSnapshot).map(\.name) == children(of: serialChild, in: serialSnapshot).map(\.name))
        }
        #expect(!(parallelSnapshot.treeStore.allNodes.contains { $0.id.hasSuffix("ignored.skip") }))
    }

    @Test func testDuplicateAssemblyChildrenAreCollapsedBeforeDirectoryTotals() {
        let kept = makeScanEngineFileNode(id: "/root/duplicate.txt", name: "kept.txt", size: 5)
        let dropped = makeScanEngineFileNode(id: kept.id, name: "dropped.txt", size: 50)
        let sibling = makeScanEngineFileNode(id: "/root/sibling.txt", name: "sibling.txt", size: 7)

        let uniqueChildren = ScanEngine.uniqueNodesForAssembly([kept, dropped, sibling])
        let directory = FileNodeRecord.directory(
            id: "/root",
            url: URL(filePath: "/root", directoryHint: .isDirectory),
            name: "root",
            children: uniqueChildren,
            lastModified: nil,
            isPackage: false,
            isAccessible: true
        )

        #expect(uniqueChildren.map(\.name) == ["kept.txt", "sibling.txt"])
        #expect(directory.allocatedSize == 12)
        #expect(directory.logicalSize == 12)
        #expect(directory.descendantFileCount == 2)
    }

    @Test func testProgressFractionIsMonotonicAndCompletes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<3 {
            let directoryURL = rootURL.appending(path: "Folder-\(directoryIndex)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<4 {
                let fileURL = directoryURL.appending(path: "File-\(fileIndex).txt")
                try Data(repeating: UInt8(fileIndex), count: 1_024).write(to: fileURL)
            }
        }

        let engine = ScanEngine()
        var progressFractions: [Double] = []

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            if case .progress(let metrics) = event {
                progressFractions.append(metrics.progressFraction)
            }
        }

        #expect(!(progressFractions.isEmpty))
        #expect(abs((try #require(progressFractions.last)) - (1)) <= 0.0001)

        for pair in zip(progressFractions, progressFractions.dropFirst()) {
            #expect(pair.1 >= pair.0)
        }
    }

    @Test func testFinalizationProgressIsEmittedDuringAssembly() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<700 {
            let directoryURL = rootURL.appending(path: "Folder-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let engine = ScanEngine()
        var finalizingProgress: [ScanMetrics] = []
        var didFinish = false

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            switch event {
            case .progress(let metrics) where metrics.isFinalizing:
                finalizingProgress.append(metrics)
            case .finished:
                didFinish = true
            case .progress, .warning, .partial:
                break
            }
        }

        #expect(didFinish)
        #expect(finalizingProgress.count >= 2)

        for pair in zip(finalizingProgress, finalizingProgress.dropFirst()) {
            #expect(pair.1.progressFraction >= pair.0.progressFraction)
        }
    }

    @Test func testEmptyDirectoryScanProducesEmptyRootNode() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        #expect(snapshot.root.isDirectory)
        #expect(snapshot.root.url.path == rootURL.path)
        #expect(rootChildren(in: snapshot).isEmpty)
        #expect(snapshot.aggregateStats.directoryCount == 1)
        #expect(snapshot.aggregateStats.fileCount == 0)
    }

    @Test func testEmptySubdirectoryIsRetainedInTree() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let emptyDirectoryURL = rootURL.appending(path: "Empty", directoryHint: .isDirectory)
        let fileURL = rootURL.appending(path: "payload.txt")

        try FileManager.default.createDirectory(at: emptyDirectoryURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let emptyNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Empty" }))
        #expect(emptyNode.isDirectory)
        #expect(children(of: emptyNode, in: snapshot).isEmpty)
        #expect(emptyNode.descendantFileCount == 0)
    }

    @Test func testByteEstimatePreventsPrematureFinalizingProgress() {
        var metrics = ScanMetrics()
        metrics.estimatedTotalBytes = 10_000
        metrics.discoveredItems = 6
        metrics.completedItems = 5
        metrics.filesVisited = 500
        metrics.bytesDiscovered = 1_200

        metrics.recalculateProgress()

        #expect(metrics.progressFraction < 0.5)
        #expect(!(metrics.isFinalizing))
    }

    @Test func testTraversalWeightDrivesProgressWithoutByteEstimate() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 10
        metrics.completedTraversalWeight = 0.5

        metrics.recalculateProgress()

        #expect(abs((metrics.progressFraction) - (0.5 * 0.95)) <= 0.0001)
    }

    @Test func testDirectoryScanProgressStaysLowWhenLittleWeightIsCompleted() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 5_000
        metrics.discoveredItems = 5_200
        metrics.completedItems = 5_000
        metrics.bytesDiscovered = 50_000_000_000
        metrics.completedTraversalWeight = 0.02

        metrics.recalculateProgress()

        #expect(metrics.progressFraction < 0.05)
    }

    @Test func testFrontierExtrapolationCapsProgressInSkewedTrees() {
        var metrics = ScanMetrics()
        // 2,000 flat files completed; one giant unexplored sibling directory remains.
        // The weight model alone would report ~99% here.
        metrics.filesVisited = 2_000
        metrics.discoveredItems = 2_001
        metrics.completedItems = 2_000
        metrics.enumeratedDirectoryCount = 1
        metrics.pendingDirectoryCount = 1
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 2_000.0 / 2_008.0

        metrics.recalculateProgress()

        #expect(metrics.progressFraction < 0.35)
    }

    @Test func testItemCountCapAppliesWhenFrontierDrainsButFilesRemain() {
        var metrics = ScanMetrics()
        // 1,000 sibling files completed, then one directory was enumerated and yielded
        // 5,000 flat files (no subdirectories), draining the frontier to zero. Most of the
        // discovered files are still unprocessed, but the weight model alone reports ~94%
        // because the 1,000 completed files held nearly all of the root's split weight.
        metrics.filesVisited = 1_000
        metrics.discoveredItems = 6_001
        metrics.completedItems = 1_000
        metrics.enumeratedDirectoryCount = 2
        metrics.pendingDirectoryCount = 0
        metrics.discoveredDirectoryCount = 2
        metrics.completedTraversalWeight = 1_000.0 / 1_008.0

        metrics.recalculateProgress()

        // The item-count cap, (completed + enumerated) / discovered ≈ 0.167, must hold the
        // bar near the true ~17% rather than letting the weight estimate jump to ~94%.
        #expect(metrics.progressFraction < 0.30)
    }

    @Test func testVolumeByteEstimateBlendsWithTraversalWeight() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.estimatedTotalBytes = 1_000
        metrics.bytesDiscovered = 500
        metrics.completedTraversalWeight = 0.3

        metrics.recalculateProgress()

        #expect(abs((metrics.progressFraction) - (((0.3 + 0.5) / 2) * 0.95)) <= 0.0001)
    }

    @Test func testFinalizationProgressMapsAboveTraversalSpan() {
        var metrics = ScanMetrics()
        metrics.filesVisited = 100
        metrics.completedTraversalWeight = 1
        metrics.recalculateProgress()

        metrics.isFinalizing = true
        metrics.finalizationFraction = 0.5
        metrics.recalculateProgress()
        #expect(abs((metrics.progressFraction) - (0.97)) <= 0.0001)

        metrics.finalizationFraction = 1
        metrics.recalculateProgress()
        #expect(abs((metrics.progressFraction) - (0.99)) <= 0.0001)

        metrics.recalculateProgress(isComplete: true)
        #expect(abs((metrics.progressFraction) - (1)) <= 0.0001)
    }

    @Test func testDirectoryBelowThresholdNotAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory with small files — well below the default 5,000-file threshold
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 100 small files — below the default 5,000 threshold
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)  // 64 bytes each
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        // The cache directory should NOT be auto-summarized (only 100 files, below threshold)
        // This test verifies the mechanism doesn't trigger at low file counts
        let cacheNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        #expect(!(cacheNode.isAutoSummarized), "Directory with only 100 files should not be auto-summarized")
        #expect(cacheNode.isDirectory)
        #expect(containsChildren(cacheNode, in: snapshot))
    }

    @Test func testAutoSummarizedDirectoryShowsFileCount() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a regular file for comparison
        let fileURL = rootURL.appending(path: "document.txt")
        try Data("Hello, World!".utf8).write(to: fileURL)

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let fileNode = try #require(rootChildren(in: snapshot).first)
        #expect(!(fileNode.isAutoSummarized))
        #expect(fileNode.itemKind == "File")
        #expect(fileNode.secondaryStatusText == nil)
    }

    @Test func testAutoSummarizeCanBeDisabledViaOptions() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a deep directory structure
        let cacheURL = rootURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create many small files
        for i in 0..<100 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 64).write(to: fileURL)
        }

        // Scan with autoSummarize disabled
        var options = ScanOptions()
        options.autoSummarizeDirectories = false

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        // Even with many files, the directory should NOT be auto-summarized
        let cacheNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "cache" }))
        #expect(!(cacheNode.isAutoSummarized))
        #expect(containsChildren(cacheNode, in: snapshot))
        #expect(children(of: cacheNode, in: snapshot).count == 100)
    }

    @Test func testCoreSimulatorDirectoryIsAutoSummarizedDespiteSparseImmediateChildren() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let coreSimulatorURL = rootURL.appending(
            path: "Library/Developer/CoreSimulator",
            directoryHint: .isDirectory
        )
        let appDataURL = coreSimulatorURL
            .appending(path: "Devices/00000000-0000-0000-0000-000000000001/data/Containers/Data/Application")
            .appending(path: "Example.appdata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDataURL, withIntermediateDirectories: true)

        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 128)
                .write(to: appDataURL.appending(path: "payload-\(index).bin"))
        }

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: ScanOptions()
        )

        let libraryNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "Library" }))
        let developerNode = try #require(children(of: libraryNode, in: snapshot).first(where: { $0.name == "Developer" }))
        let coreSimulatorNode = try #require(children(of: developerNode, in: snapshot).first(where: { $0.name == "CoreSimulator" }))

        #expect(coreSimulatorNode.isAutoSummarized)
        #expect(!(containsChildren(coreSimulatorNode, in: snapshot)))
        #expect(coreSimulatorNode.descendantFileCount == 3)
        #expect(coreSimulatorNode.logicalSize >= 384)
    }

    @Test func testDirectoryIsAutoSummarizedWithLowThresholds() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2: rootURL/projects/cache/
        // Depth 0 = rootURL, depth 1 = projects, depth 2 = cache
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // Create 20 small files — enough to trigger with low thresholds
        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)  // 32 bytes each
        }

        // Use low thresholds: min 10 files, max 256 bytes average, min depth 2
        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        #expect(cacheNode.isAutoSummarized, "Directory should be auto-summarized with low thresholds")
        #expect(!(containsChildren(cacheNode, in: snapshot)), "Auto-summarized directory should have no children")
        #expect(cacheNode.descendantFileCount == 20, "Should report correct file count")
        #expect(cacheNode.itemKind == "Summarized")
        #expect(cacheNode.secondaryStatusText == "Summarized (20 files)")
    }

    @Test func testDeepTinyFileDirectoryIsAutoSummarized() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        #expect(cacheNode.isAutoSummarized)
        #expect(!(containsChildren(cacheNode, in: snapshot)))
        #expect(cacheNode.descendantFileCount == 12)
    }

    @Test func testNodeModulesPnpmStoreAutoSummarizesAtShallowDepth() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/left-pad@1.3.0/node_modules/left-pad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: packageURL.appending(path: "file-\(index).js"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.tuning.autoSummarizeMinFileCount = 20
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        #expect(nodeModulesNode.isAutoSummarized)
        #expect(!(containsChildren(nodeModulesNode, in: snapshot)))
        #expect(nodeModulesNode.descendantFileCount == 20)
    }

    @Test func testScopedNodePackageContainerAutoSummarizesAtShallowDepth() async throws {
        let nodeModulesURL = try makeTemporaryDirectory().appending(path: "node_modules", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: nodeModulesURL.deletingLastPathComponent()) }

        let packageURL = nodeModulesURL
            .appending(path: "@radix-ui/colors/dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 24)
                .write(to: packageURL.appending(path: "token-\(index).js"))
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 20
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: nodeModulesURL),
            options: options
        )

        let scopeNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "@radix-ui" }))
        #expect(scopeNode.isAutoSummarized)
        #expect(!(containsChildren(scopeNode, in: snapshot)))
        #expect(scopeNode.descendantFileCount == 20)
    }

    @Test func testNestedNodeModulesForestAutoSummarizesThroughSparseParent() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let nodeModulesURL = rootURL
            .appending(path: "workspace/packages/app/node_modules", directoryHint: .isDirectory)
        let packageURL = nodeModulesURL
            .appending(path: "vite/dist/client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 40)
                .write(to: packageURL.appending(path: "chunk-\(index).js"))
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 20
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let workspaceNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "workspace" }))
        let packagesNode = try #require(children(of: workspaceNode, in: snapshot).first(where: { $0.name == "packages" }))
        let appNode = try #require(children(of: packagesNode, in: snapshot).first(where: { $0.name == "app" }))
        let nodeModulesNode = try #require(children(of: appNode, in: snapshot).first(where: { $0.name == "node_modules" }))
        #expect(nodeModulesNode.isAutoSummarized)
        #expect(!(containsChildren(nodeModulesNode, in: snapshot)))
        #expect(nodeModulesNode.descendantFileCount == 20)
    }

    @Test func testSparseAncestorDefersAutoSummarizationToDenseDescendant() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        let denseURL = cacheURL.appending(path: "dense", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: denseURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 32)
                .write(to: denseURL.appending(path: "payload-\(index).tmp"))
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 20
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        let denseNode = try #require(children(of: cacheNode, in: snapshot).first(where: { $0.name == "dense" }))

        #expect(!(cacheNode.isAutoSummarized))
        #expect(denseNode.isAutoSummarized)
        #expect(!(containsChildren(denseNode, in: snapshot)))
        #expect(denseNode.descendantFileCount == 20)
    }

    @Test func testAutoSummarizedDirectoryIncludesPackageLeafContents() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        let packageBinaryURL = cacheURL
            .appending(path: "Tool.app", directoryHint: .isDirectory)
            .appending(path: "Contents/MacOS/Tool")
        try FileManager.default.createDirectory(at: packageBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 2_048).write(to: packageBinaryURL)

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        #expect(cacheNode.isAutoSummarized)
        #expect(cacheNode.descendantFileCount == 13)
        #expect(cacheNode.logicalSize >= (12 * 32) + 2_048)
    }

    @Test func testAutoSummarizedDirectoryCountsAsSingleVisitedDirectory() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i % 256), count: 32).write(to: fileURL)
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var finalMetrics = ScanMetrics()

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .progress(let metrics) = event {
                finalMetrics = metrics
            }
        }

        #expect(finalMetrics.directoriesVisited == 3)
        #expect(finalMetrics.filesVisited == 20)
    }

    @Test func testAutoSummarizedDirectoryReleasesChildDirectoryDiscoveryCounts() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let shardURL = cacheURL.appending(path: "shard-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shardURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 32).write(to: shardURL.appending(path: "payload.tmp"))
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let engine = ScanEngine()
        var progressSnapshots: [ScanMetrics] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            switch event {
            case .progress(let metrics):
                progressSnapshots.append(metrics)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .warning, .partial:
                break
            }
        }

        let snapshot = try #require(finalSnapshot)
        let finalMetrics = try #require(progressSnapshots.last)
        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))

        #expect(cacheNode.isAutoSummarized)
        #expect(finalMetrics.enumeratedDirectoryCount == 3)
        #expect(finalMetrics.discoveredDirectoryCount == 3)
        #expect(finalMetrics.pendingDirectoryCount == 0)
        #expect(abs((finalMetrics.progressFraction) - (1)) <= 0.0001)
    }

    @Test func testDirectoryNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Create a directory at depth 2 with 20 LARGE files
        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<20 {
            let fileURL = cacheURL.appending(path: "file_\(i).dat")
            try Data(repeating: UInt8(i % 256), count: 100_000).write(to: fileURL)  // 100 KB each
        }

        var options = ScanOptions()
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 4_096  // 4 KB max average
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        #expect(!(cacheNode.isAutoSummarized), "Directory with large files should not be auto-summarized")
        #expect(containsChildren(cacheNode, in: snapshot))
        #expect(children(of: cacheNode, in: snapshot).count == 20)
    }

    @Test func testNodeDependencyLayoutNotAutoSummarizedWhenFilesAreLarge() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appending(path: "node_modules", directoryHint: .isDirectory)
            .appending(path: ".pnpm/large-payload@1.0.0/node_modules/large-payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for index in 0..<20 {
            try Data(repeating: UInt8(index), count: 8_192)
                .write(to: packageURL.appending(path: "asset-\(index).dat"))
        }

        var options = ScanOptions(includeHiddenFiles: true)
        options.tuning.autoSummarizeMinFileCount = 20
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let nodeModulesNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "node_modules" }))
        #expect(!(nodeModulesNode.isAutoSummarized))
        #expect(containsChildren(nodeModulesNode, in: snapshot))
    }

    @Test func testAutoSummarizedDirectoryExcludesHiddenFilesWhenHiddenFilesDisabled() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let projectsURL = rootURL.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let cacheURL = projectsURL.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        for i in 0..<12 {
            let fileURL = cacheURL.appending(path: "file_\(i).tmp")
            try Data(repeating: UInt8(i), count: 32).write(to: fileURL)
        }

        for i in 0..<3 {
            let hiddenFileURL = cacheURL.appending(path: ".hidden_\(i).tmp")
            try Data(repeating: 0x7F, count: 32).write(to: hiddenFileURL)
        }

        var options = ScanOptions(includeHiddenFiles: false)
        options.tuning.autoSummarizeMinFileCount = 10
        options.tuning.autoSummarizeMaxAverageFileSize = 256
        options.tuning.autoSummarizeMinDepthForSummarization = 2

        let snapshot = try await finishedSnapshot(
            target: ScanTarget(url: rootURL),
            options: options
        )

        let projectsNode = try #require(rootChildren(in: snapshot).first(where: { $0.name == "projects" }))
        let cacheNode = try #require(children(of: projectsNode, in: snapshot).first(where: { $0.name == "cache" }))
        #expect(cacheNode.isAutoSummarized)
        #expect(cacheNode.descendantFileCount == 12)
        #expect(cacheNode.logicalSize == 12 * 32)
    }
}

private func finishedSnapshot(
    target: ScanTarget,
    options: ScanOptions,
    engine: ScanEngine = ScanEngine()
) async throws -> ScanSnapshot {
    for try await event in engine.scan(target: target, options: options) {
        if case .finished(let snapshot) = event {
            return snapshot
        }
    }

    Issue.record("Expected scan to produce a final snapshot")
    throw CancellationError()
}

private func rootChildren(in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: snapshot.root.id)
}

extension ScanEngineTests {
    @Test func testScanEmitsPartialTreeBeforeFinishing() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for directoryIndex in 0..<4 {
            let directoryURL = rootURL.appending(
                path: "dir\(directoryIndex)", directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for fileIndex in 0..<8 {
                try Data(repeating: 0x42, count: 512)
                    .write(to: directoryURL.appending(path: "file\(fileIndex).bin"))
            }
        }

        let engine = ScanEngine()
        var partialStores: [FileTreeStore] = []
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: ScanOptions()) {
            switch event {
            case .partial(let store):
                partialStores.append(store)
            case .finished(let snapshot):
                finalSnapshot = snapshot
            case .progress, .warning:
                break
            }
        }

        let snapshot = try #require(finalSnapshot)

        // At least one live partial tree arrives before the scan finishes,
        // rooted at the scan target.
        let firstPartial = try #require(partialStores.first)
        #expect(firstPartial.root.id == snapshot.root.id)

        // Partial sizes only grow; none may exceed the exact final total.
        var previousSize: Int64 = 0
        for store in partialStores {
            #expect(store.root.allocatedSize >= previousSize)
            previousSize = store.root.allocatedSize
        }
        #expect(previousSize <= snapshot.root.allocatedSize)
    }
}

private func children(of node: FileNodeRecord, in snapshot: ScanSnapshot) -> [FileNodeRecord] {
    snapshot.treeStore.children(of: node.id)
}

private func containsChildren(_ node: FileNodeRecord, in snapshot: ScanSnapshot) -> Bool {
    snapshot.treeStore.containsChildren(id: node.id)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeScanEngineFileNode(id: String, name: String, size: Int64) -> FileNodeRecord {
    FileNodeRecord(
        id: id,
        url: URL(filePath: id),
        name: name,
        isDirectory: false,
        isSymbolicLink: false,
        allocatedSize: size,
        logicalSize: size,
        descendantFileCount: 1,
        lastModified: nil,
        isPackage: false,
        isAccessible: true,
        isSelfAccessible: true,
        isSynthetic: false,
        isAutoSummarized: false
    )
}

private enum AsyncTestTimeout: Error {
    case timedOut
}

private final class DirectoryEnumerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = isCancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

private final class SlowDirectoryObjectEnumerator: ScanEngine.DirectoryObjectEnumerating, @unchecked Sendable {
    let totalCount: Int
    private let rootURL: URL
    private let lock = NSLock()
    private var nextIndex = 0

    init(rootURL: URL, totalCount: Int) {
        self.rootURL = rootURL
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func nextObject() -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < totalCount else { return nil }
        let childURL = rootURL.appending(path: "payload-\(nextIndex).tmp")
        nextIndex += 1
        Thread.sleep(forTimeInterval: 0.0005)
        return childURL
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for directory object enumeration.", sourceLocation: sourceLocation)
    }
}

private final class CancellableDirectoryContentsProbe: @unchecked Sendable {
    let totalCount: Int
    private let lock = NSLock()
    private var produced = 0

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    var producedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return produced
    }

    func contents(
        for url: URL,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(totalCount)

        for index in 0..<totalCount {
            if index.isMultiple(of: 8) {
                try cancellationCheck()
            }
            recordProducedChild()
            Thread.sleep(forTimeInterval: 0.0005)
            urls.append(url.appending(path: "payload-\(index).tmp"))
        }

        return urls
    }

    func waitUntilProduced(
        _ minimumCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if producedCount >= minimumCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for directory contents production.", sourceLocation: sourceLocation)
    }

    private func recordProducedChild() {
        lock.lock()
        produced += 1
        lock.unlock()
    }
}

private final class BlockingDirectoryContentsProbe: @unchecked Sendable {
    private let blockedURL: URL
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    init(blockedURL: URL) {
        self.blockedURL = blockedURL
    }

    func contents(for url: URL) throws -> [URL] {
        guard url == blockedURL else { return [] }

        condition.lock()
        defer { condition.unlock() }
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        return []
    }

    func waitUntilBlocked(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if blocked {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for directory contents blocking.", sourceLocation: sourceLocation)
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    private var blocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: duration)
            throw AsyncTestTimeout.timedOut
        }

        guard let result = try await group.next() else {
            throw AsyncTestTimeout.timedOut
        }
        group.cancelAll()
        return result
    }
}
