import Foundation
import Testing
@testable import NeodiskKit

@Suite struct ScanSnapshotCacheTests {
    @Test func testRoundTripPreservesTreeMetadataAndWarnings() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let snapshot = makeRichSnapshot(rootPath: "/cache/root")

        try await cache.save(snapshot)
        let loaded = try #require(await cache.loadSnapshot(for: snapshot.target))

        #expect(loaded.isComplete)
        #expect(loaded.target.id == snapshot.target.id)
        #expect(loaded.target.displayName == snapshot.target.displayName)
        #expect(loaded.target.kind == snapshot.target.kind)
        #expect(abs(loaded.startedAt.timeIntervalSince(snapshot.startedAt)) < 0.01)
        let finishedAt = try #require(loaded.finishedAt)
        let expectedFinishedAt = try #require(snapshot.finishedAt)
        #expect(abs(finishedAt.timeIntervalSince(expectedFinishedAt)) < 0.01)

        #expect(loaded.scanWarnings.count == snapshot.scanWarnings.count)
        for (loadedWarning, original) in zip(loaded.scanWarnings, snapshot.scanWarnings) {
            #expect(loadedWarning.path == original.path)
            #expect(loadedWarning.message == original.message)
            #expect(loadedWarning.category == original.category)
        }

        expectEqualTrees(loaded.treeStore, snapshot.treeStore)

        let loadedStats = loaded.aggregateStats
        let originalStats = snapshot.aggregateStats
        #expect(loadedStats.totalAllocatedSize == originalStats.totalAllocatedSize)
        #expect(loadedStats.totalLogicalSize == originalStats.totalLogicalSize)
        #expect(loadedStats.fileCount == originalStats.fileCount)
        #expect(loadedStats.directoryCount == originalStats.directoryCount)
        #expect(loadedStats.accessibleItemCount == originalStats.accessibleItemCount)
        #expect(loadedStats.inaccessibleItemCount == originalStats.inaccessibleItemCount)
    }

    @Test func testDuplicateHashCacheRoundTripAndRemoveAll() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)

        // Missing file: a usable empty cache, never an error.
        let empty = await cache.loadDuplicateHashCache()
        #expect(empty.entryCount == 0)

        let stamp = DuplicateHashCache.FileStamp(size: 10, modifiedAtNanoseconds: 20, inode: 30)
        empty.storeDigest("abc", for: "/x", tier: .full, stamp: stamp)
        await cache.saveDuplicateHashCache(empty)

        let reloaded = await cache.loadDuplicateHashCache()
        #expect(reloaded.cachedDigest(for: "/x", tier: .full, stamp: stamp) == "abc")

        // A clean cache save is a no-op — the file keeps its contents.
        await cache.saveDuplicateHashCache(DuplicateHashCache())
        let untouched = await cache.loadDuplicateHashCache()
        #expect(untouched.entryCount == 1)

        // Clearing the cache from Settings removes the hashes too.
        await cache.removeAll()
        let cleared = await cache.loadDuplicateHashCache()
        #expect(cleared.entryCount == 0)
    }

    @Test func testSavingIncompleteSnapshotThrows() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)

        let file = makeTestFileNode(id: "/partial/file.txt", name: "file.txt", size: 5)
        let root = makeTestDirectoryNode(id: "/partial", name: "partial", children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        let partial = ScanSnapshot(
            target: makeTestTarget("/partial"),
            treeStore: store,
            startedAt: Date(),
            finishedAt: nil,
            scanWarnings: [],
            aggregateStats: store.aggregateStats,
            isComplete: false
        )

        await #expect(throws: ScanSnapshotCacheError.self) {
            try await cache.save(partial)
        }
        #expect(await cache.loadSnapshot(for: partial.target) == nil)
    }

    @Test func testCorruptFileIsDiscardedAndDeleted() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let snapshot = makeRichSnapshot(rootPath: "/cache/corrupt")

        try await cache.save(snapshot)
        let fileURL = try #require(singleCacheFileURL(in: cacheDirectory))

        // Truncate to half: header parses, node payload is cut short.
        let original = try Data(contentsOf: fileURL)
        try original.prefix(original.count / 2).write(to: fileURL)

        #expect(await cache.loadSnapshot(for: snapshot.target) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // Arbitrary garbage: header fails outright.
        try await cache.save(snapshot)
        try Data((0..<128).map { UInt8($0) }).write(to: fileURL)
        #expect(await cache.loadSnapshot(for: snapshot.target) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func testUnsupportedFormatVersionIsDiscardedAndDeleted() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let snapshot = makeRichSnapshot(rootPath: "/cache/versioned")

        try await cache.save(snapshot)
        let fileURL = try #require(singleCacheFileURL(in: cacheDirectory))

        var data = try Data(contentsOf: fileURL)
        // Bytes 4..<8 hold the little-endian format version.
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(999).littleEndian) { Data($0) })
        try data.write(to: fileURL)

        #expect(await cache.loadSnapshot(for: snapshot.target) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func testVersion1FileStillLoads() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let snapshot = makeRichSnapshot(rootPath: "/cache/legacy")

        // Save normally to learn the file path, then overwrite with a
        // version-1 (uncompressed payload) encoding of the same snapshot.
        try await cache.save(snapshot)
        let fileURL = try #require(singleCacheFileURL(in: cacheDirectory))
        try ScanSnapshotCodec.encode(snapshot, version: 1).write(to: fileURL)

        let loaded = try #require(await cache.loadSnapshot(for: snapshot.target))
        // v1 predates clone info; everything else survives.
        expectEqualTrees(loaded.treeStore, snapshot.treeStore, carriesCloneInfo: false)
        #expect(loaded.scanWarnings.count == snapshot.scanWarnings.count)
    }

    @Test func testCurrentFormatIsSmallerThanVersion1() throws {
        let snapshot = makeRichSnapshot(rootPath: "/cache/compressed")
        let v1 = try ScanSnapshotCodec.encode(snapshot, version: 1)
        let v2 = try ScanSnapshotCodec.encode(snapshot)
        #expect(v2.count < v1.count)
        let roundTripped = try ScanSnapshotCodec.decode(v2)
        expectEqualTrees(roundTripped.treeStore, snapshot.treeStore)
    }

    @Test func testPruneDeletesOrphansAndIndexesSurvivors() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)

        let kept = makeRichSnapshot(rootPath: "/cache/kept")
        let orphan = makeRichSnapshot(rootPath: "/cache/orphan")
        try await cache.save(kept)
        try await cache.save(orphan)

        let index = await cache.pruneAndIndex(keepingTargetIDs: [kept.target.id])

        #expect(index.keys.sorted() == [kept.target.id])
        let keptInfo = try #require(index[kept.target.id])
        let expectedDate = try #require(kept.finishedAt)
        #expect(abs(keptInfo.lastScanDate.timeIntervalSince(expectedDate)) < 0.01)
        let duration = try #require(keptInfo.lastScanDuration)
        #expect(abs(duration - expectedDate.timeIntervalSince(kept.startedAt)) < 0.01)
        #expect(keptInfo.nodeCount == kept.treeStore.nodeCount)
        #expect(!keptInfo.hasPreviousSnapshot)

        #expect(await cache.loadSnapshot(for: orphan.target) == nil)
        #expect(await cache.loadSnapshot(for: kept.target) != nil)
    }

    @Test func testSavingRotatesPreviousSnapshot() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/rotated")

        let firstFile = makeTestFileNode(id: "/cache/rotated/first.txt", name: "first.txt", size: 10)
        let firstRoot = makeTestDirectoryNode(id: target.id, name: "rotated", children: [firstFile])
        let firstStore = FileTreeStore(root: firstRoot, childrenByID: [firstRoot.id: [firstFile]])
        try await cache.save(makeTestSnapshot(target: target, root: firstRoot, store: firstStore))
        #expect(await cache.loadPreviousSnapshot(for: target) == nil)

        let secondFile = makeTestFileNode(id: "/cache/rotated/second.txt", name: "second.txt", size: 99)
        let secondRoot = makeTestDirectoryNode(id: target.id, name: "rotated", children: [secondFile])
        let secondStore = FileTreeStore(root: secondRoot, childrenByID: [secondRoot.id: [secondFile]])
        try await cache.save(makeTestSnapshot(target: target, root: secondRoot, store: secondStore))

        let latest = try #require(await cache.loadSnapshot(for: target))
        #expect(latest.treeStore.node(id: secondFile.id) != nil)
        let previous = try #require(await cache.loadPreviousSnapshot(for: target))
        #expect(previous.treeStore.node(id: firstFile.id) != nil)
        #expect(previous.treeStore.node(id: secondFile.id) == nil)

        let index = await cache.pruneAndIndex(keepingTargetIDs: [target.id])
        #expect(index[target.id]?.hasPreviousSnapshot == true)

        // A third save drops the first snapshot entirely.
        let thirdFile = makeTestFileNode(id: "/cache/rotated/third.txt", name: "third.txt", size: 5)
        let thirdRoot = makeTestDirectoryNode(id: target.id, name: "rotated", children: [thirdFile])
        let thirdStore = FileTreeStore(root: thirdRoot, childrenByID: [thirdRoot.id: [thirdFile]])
        try await cache.save(makeTestSnapshot(target: target, root: thirdRoot, store: thirdStore))
        let rotated = try #require(await cache.loadPreviousSnapshot(for: target))
        #expect(rotated.treeStore.node(id: secondFile.id) != nil)
        #expect(rotated.treeStore.node(id: firstFile.id) == nil)
    }

    @Test func testUnchangedContentSaveKeepsPreviousBaseline() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/unchanged")

        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        let changed = try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 300)]))
        #expect(changed.rotatedPrevious)
        #expect(changed.hasPreviousSnapshot)

        // A content-identical rescan becomes the latest (fresh scan date)
        // but skips the rotation: the previous slot keeps the older baseline
        // instead of a same-content copy that would diff to nothing.
        let rescanDate = Date(timeIntervalSinceReferenceDate: 777_000_000)
        let unchanged = try await cache.save(makeFileSnapshot(
            target: target, files: [("a.bin", 300)], finishedAt: rescanDate
        ))
        #expect(!unchanged.rotatedPrevious)
        #expect(unchanged.hasPreviousSnapshot)

        let latest = try #require(await cache.loadSnapshot(for: target))
        let latestFinishedAt = try #require(latest.finishedAt)
        #expect(abs(latestFinishedAt.timeIntervalSince(rescanDate)) < 0.01)
        let previous = try #require(await cache.loadPreviousSnapshot(for: target))
        #expect(previous.treeStore.node(id: target.id + "/a.bin")?.allocatedSize == 100)
    }

    @Test func testUnchangedFirstRescanCreatesNoPreviousSnapshot() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/unchanged-first")

        let first = try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        #expect(!first.rotatedPrevious)
        #expect(!first.hasPreviousSnapshot)

        let rescan = try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        #expect(!rescan.rotatedPrevious)
        #expect(!rescan.hasPreviousSnapshot)
        #expect(await cache.loadPreviousSnapshot(for: target) == nil)
    }

    @Test func testTimestampOnlyChangesDoNotRotate() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/touched")

        // The change surfaces never read lastModified, so a scan differing
        // only there must count as unchanged — rotating it in would destroy
        // the baseline to show an empty diff.
        func snapshot(modified: Date) -> ScanSnapshot {
            let file = makeTestFileNode(
                id: target.id + "/a.bin", name: "a.bin", size: 100, lastModified: modified
            )
            let root = makeTestDirectoryNode(id: target.id, name: "touched", children: [file])
            let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
            return makeTestSnapshot(target: target, root: root, store: store)
        }
        try await cache.save(snapshot(modified: Date(timeIntervalSinceReferenceDate: 1_000)))
        let outcome = try await cache.save(
            snapshot(modified: Date(timeIntervalSinceReferenceDate: 2_000))
        )
        #expect(!outcome.rotatedPrevious)
        #expect(await cache.loadPreviousSnapshot(for: target) == nil)
    }

    @Test func testDigestlessLatestFileStillRotates() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/pre-digest")

        // Strip the digest from the saved file's metadata JSON, simulating a
        // file written before the field existed: an identical rescan can't
        // prove it is unchanged, so it rotates like it always did.
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        let latestURL = try #require(singleCacheFileURL(in: cacheDirectory))
        let data = try Data(contentsOf: latestURL)
        let metadataLength = data.subdata(in: 8..<12).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.load(as: UInt32.self)))
        }
        var json = try #require(try JSONSerialization.jsonObject(
            with: data.subdata(in: 12..<(12 + metadataLength))
        ) as? [String: Any])
        #expect(json.removeValue(forKey: "changeDigest") != nil)
        let strippedMetadata = try JSONSerialization.data(withJSONObject: json)
        var rebuilt = data.prefix(8)
        rebuilt.append(withUnsafeBytes(of: UInt32(strippedMetadata.count).littleEndian) { Data($0) })
        rebuilt.append(strippedMetadata)
        rebuilt.append(data.suffix(from: 12 + metadataLength))
        try rebuilt.write(to: latestURL)

        let outcome = try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        #expect(outcome.rotatedPrevious)
        #expect(await cache.loadPreviousSnapshot(for: target) != nil)
    }

    @Test func testPruneDeletesBothSlotsOfRemovedTargets() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)

        let orphan = makeRichSnapshot(rootPath: "/cache/gone")
        try await cache.save(orphan)
        // A changed rescan, so the first save rotates into the previous slot.
        try await cache.save(makeFileSnapshot(target: orphan.target, files: [("grew.bin", 7)]))
        let kept = makeRichSnapshot(rootPath: "/cache/kept-both")
        try await cache.save(kept)

        let index = await cache.pruneAndIndex(keepingTargetIDs: [kept.target.id])

        #expect(index.keys.sorted() == [kept.target.id])
        #expect(await cache.loadSnapshot(for: orphan.target) == nil)
        #expect(await cache.loadPreviousSnapshot(for: orphan.target) == nil)
        #expect(cacheFileURLs(in: cacheDirectory).count == 1)
    }

    @Test func testPruneDeletesPreviousSnapshotWhoseLatestIsUnreadable() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let snapshot = makeRichSnapshot(rootPath: "/cache/broken-latest")

        try await cache.save(snapshot)
        // A changed rescan, so the first save rotates into the previous slot.
        try await cache.save(makeFileSnapshot(target: snapshot.target, files: [("grew.bin", 7)]))
        let latestURL = try #require(
            cacheFileURLs(in: cacheDirectory).first { !$0.lastPathComponent.contains(".prev.") }
        )
        try Data((0..<128).map { UInt8($0) }).write(to: latestURL)

        let index = await cache.pruneAndIndex(keepingTargetIDs: [snapshot.target.id])

        // The unreadable latest is pruned, and the previous snapshot is
        // unreachable without it, so it goes too.
        #expect(index.isEmpty)
        #expect(cacheFileURLs(in: cacheDirectory).isEmpty)
    }

    @Test func testRemoveSnapshotRemovesPreviousToo() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let snapshot = makeRichSnapshot(rootPath: "/cache/both-slots")

        try await cache.save(snapshot)
        // A changed rescan, so the first save rotates into the previous slot.
        try await cache.save(makeFileSnapshot(target: snapshot.target, files: [("grew.bin", 7)]))
        #expect(await cache.loadPreviousSnapshot(for: snapshot.target) != nil)

        await cache.removeSnapshot(forTargetID: snapshot.target.id)
        #expect(await cache.loadSnapshot(for: snapshot.target) == nil)
        #expect(await cache.loadPreviousSnapshot(for: snapshot.target) == nil)
        #expect(await cache.totalSizeOnDisk() == 0)
    }

    @Test func testRemoveSnapshotAndRemoveAll() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)

        let first = makeRichSnapshot(rootPath: "/cache/first")
        let second = makeRichSnapshot(rootPath: "/cache/second")
        try await cache.save(first)
        try await cache.save(second)
        #expect(await cache.totalSizeOnDisk() > 0)

        await cache.removeSnapshot(forTargetID: first.target.id)
        #expect(await cache.loadSnapshot(for: first.target) == nil)
        #expect(await cache.loadSnapshot(for: second.target) != nil)

        await cache.removeAll()
        #expect(await cache.loadSnapshot(for: second.target) == nil)
        #expect(await cache.totalSizeOnDisk() == 0)
    }

    @Test func testAuxiliaryDataLivesAndDiesWithItsSnapshot() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)

        let snapshot = makeRichSnapshot(rootPath: "/cache/aux")
        let targetID = snapshot.target.id
        try await cache.save(snapshot)

        #expect(await cache.loadAuxiliaryData(forTargetID: targetID) == nil)
        let payload = Data("kind-stats".utf8)
        await cache.saveAuxiliaryData(payload, forTargetID: targetID)
        #expect(await cache.loadAuxiliaryData(forTargetID: targetID) == payload)
        #expect(await cache.totalSizeOnDisk() > 0)

        // Pruning keeps auxiliary data whose snapshot survives …
        _ = await cache.pruneAndIndex(keepingTargetIDs: [targetID])
        #expect(await cache.loadAuxiliaryData(forTargetID: targetID) == payload)

        // … and drops it with a pruned or removed snapshot.
        _ = await cache.pruneAndIndex(keepingTargetIDs: [])
        #expect(await cache.loadAuxiliaryData(forTargetID: targetID) == nil)

        try await cache.save(snapshot)
        await cache.saveAuxiliaryData(payload, forTargetID: targetID)
        await cache.removeSnapshot(forTargetID: targetID)
        #expect(await cache.loadAuxiliaryData(forTargetID: targetID) == nil)

        await cache.saveAuxiliaryData(payload, forTargetID: targetID)
        await cache.removeAll()
        #expect(await cache.loadAuxiliaryData(forTargetID: targetID) == nil)
        #expect(await cache.totalSizeOnDisk() == 0)
    }

    @Test func testResavingReplacesPreviousSnapshotForTarget() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/replaced")

        let oldFile = makeTestFileNode(id: "/cache/replaced/old.txt", name: "old.txt", size: 10)
        let oldRoot = makeTestDirectoryNode(id: target.id, name: "replaced", children: [oldFile])
        let oldStore = FileTreeStore(root: oldRoot, childrenByID: [oldRoot.id: [oldFile]])
        try await cache.save(makeTestSnapshot(target: target, root: oldRoot, store: oldStore))

        let newFile = makeTestFileNode(id: "/cache/replaced/new.txt", name: "new.txt", size: 99)
        let newRoot = makeTestDirectoryNode(id: target.id, name: "replaced", children: [newFile])
        let newStore = FileTreeStore(root: newRoot, childrenByID: [newRoot.id: [newFile]])
        try await cache.save(makeTestSnapshot(target: target, root: newRoot, store: newStore))

        let loaded = try #require(await cache.loadSnapshot(for: target))
        #expect(loaded.treeStore.node(id: newFile.id) != nil)
        #expect(loaded.treeStore.node(id: oldFile.id) == nil)
    }

    // MARK: - Cached change list (`.nddiff`)

    @Test func testChangeListCacheHitMissAndInvalidation() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/nddiff")

        // No previous snapshot yet: nothing to key on, so save is a no-op.
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        #expect(await cache.changeListCacheKey(forTargetID: target.id, entryLimit: 500) == nil)
        await cache.saveChangeList(
            makeEmptyList(), comparisonDate: nil, forTargetID: target.id, entryLimit: 500
        )
        #expect(await cache.loadChangeList(forTargetID: target.id, entryLimit: 500) == nil)

        // Second save rotates the first into the previous slot: now both
        // files exist and a diff can be keyed and persisted.
        let previousStore = makeFileStore(target: target, files: [("a.bin", 100)])
        let currentStore = makeFileStore(target: target, files: [("a.bin", 300), ("b.bin", 50)])
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 300), ("b.bin", 50)]))
        let list = ScanChangeList.build(current: currentStore, previous: previousStore, entryLimit: 500)
        let comparisonDate = Date(timeIntervalSinceReferenceDate: 12_345)
        await cache.saveChangeList(
            list, comparisonDate: comparisonDate, forTargetID: target.id, entryLimit: 500
        )

        // Hit: same files, same limit.
        let hit = try #require(await cache.loadChangeList(forTargetID: target.id, entryLimit: 500))
        #expect(hit.list == list)
        #expect(hit.comparisonDate.map { abs($0.timeIntervalSince(comparisonDate)) < 0.001 } == true)

        // Miss: a different entry limit is a different key.
        #expect(await cache.loadChangeList(forTargetID: target.id, entryLimit: 250) == nil)

        // Invalidation: a third save rotates the files, changing their
        // identity, so the stale diff no longer matches.
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 300), ("c.bin", 9)]))
        #expect(await cache.loadChangeList(forTargetID: target.id, entryLimit: 500) == nil)
    }

    @Test func testChangeListCacheIsPrunedAndRemovedWithItsSnapshot() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/nddiff-prune")

        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 300)]))
        await cache.saveChangeList(
            makeEmptyList(), comparisonDate: nil, forTargetID: target.id, entryLimit: 500
        )
        #expect(changeListFileURLs(in: cacheDirectory).count == 1)

        // Pruning keeps the diff whose snapshot survives …
        _ = await cache.pruneAndIndex(keepingTargetIDs: [target.id])
        #expect(changeListFileURLs(in: cacheDirectory).count == 1)

        // … and drops it with a pruned snapshot.
        _ = await cache.pruneAndIndex(keepingTargetIDs: [])
        #expect(changeListFileURLs(in: cacheDirectory).isEmpty)

        // removeSnapshot and removeAll clear it too, and it counts toward the
        // total on disk.
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 300)]))
        await cache.saveChangeList(
            makeEmptyList(), comparisonDate: nil, forTargetID: target.id, entryLimit: 500
        )
        #expect(await cache.totalSizeOnDisk() > 0)
        await cache.removeSnapshot(forTargetID: target.id)
        #expect(changeListFileURLs(in: cacheDirectory).isEmpty)

        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 300)]))
        await cache.saveChangeList(
            makeEmptyList(), comparisonDate: nil, forTargetID: target.id, entryLimit: 500
        )
        await cache.removeAll()
        #expect(changeListFileURLs(in: cacheDirectory).isEmpty)
        #expect(await cache.totalSizeOnDisk() == 0)
    }

    // MARK: - Cached duplicate results (`.nddup`)

    @Test func testDuplicateResultsCacheHitMissAndInvalidation() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/nddup")
        let minimumFileSize: Int64 = 1 << 20

        // No snapshot yet: nothing to key on, so save is a no-op.
        #expect(await cache.duplicateResultsCacheKey(
            forTargetID: target.id, minimumFileSize: minimumFileSize
        ) == nil)
        await cache.saveDuplicateResults(
            makeDuplicateResults(), computedAt: Date(), forTargetID: target.id, minimumFileSize: minimumFileSize
        )
        #expect(await cache.loadDuplicateResults(
            forTargetID: target.id, minimumFileSize: minimumFileSize
        ) == nil)

        // A single snapshot is enough to key a duplicate result (unlike the
        // diff, which needs a rotated predecessor).
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        let results = makeDuplicateResults()
        let computedAt = Date(timeIntervalSinceReferenceDate: 54_321)
        await cache.saveDuplicateResults(
            results, computedAt: computedAt, forTargetID: target.id, minimumFileSize: minimumFileSize
        )

        // Hit: same snapshot file, same minimum file size.
        let hit = try #require(await cache.loadDuplicateResults(
            forTargetID: target.id, minimumFileSize: minimumFileSize
        ))
        #expect(hit.results == results)
        #expect(abs(hit.computedAt.timeIntervalSince(computedAt)) < 0.001)

        // Miss: a different minimum file size is a different key.
        #expect(await cache.loadDuplicateResults(
            forTargetID: target.id, minimumFileSize: 2 << 20
        ) == nil)

        // Invalidation: a rescan rewrites the snapshot file, changing its
        // identity, so the stale result no longer matches.
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100), ("b.bin", 500)]))
        #expect(await cache.loadDuplicateResults(
            forTargetID: target.id, minimumFileSize: minimumFileSize
        ) == nil)
    }

    @Test func testDuplicateResultsCacheIsPrunedAndRemovedWithItsSnapshot() async throws {
        let cacheDirectory = makeTemporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        let target = makeTestTarget("/cache/nddup-prune")
        let minimumFileSize: Int64 = 1 << 20

        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        await cache.saveDuplicateResults(
            makeDuplicateResults(), computedAt: Date(), forTargetID: target.id, minimumFileSize: minimumFileSize
        )
        #expect(duplicateResultsFileURLs(in: cacheDirectory).count == 1)

        // Pruning keeps the result whose snapshot survives …
        _ = await cache.pruneAndIndex(keepingTargetIDs: [target.id])
        #expect(duplicateResultsFileURLs(in: cacheDirectory).count == 1)

        // … and drops it with a pruned snapshot.
        _ = await cache.pruneAndIndex(keepingTargetIDs: [])
        #expect(duplicateResultsFileURLs(in: cacheDirectory).isEmpty)

        // removeSnapshot and removeAll clear it too, and it counts toward the
        // total on disk.
        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        await cache.saveDuplicateResults(
            makeDuplicateResults(), computedAt: Date(), forTargetID: target.id, minimumFileSize: minimumFileSize
        )
        #expect(await cache.totalSizeOnDisk() > 0)
        await cache.removeSnapshot(forTargetID: target.id)
        #expect(duplicateResultsFileURLs(in: cacheDirectory).isEmpty)

        try await cache.save(makeFileSnapshot(target: target, files: [("a.bin", 100)]))
        await cache.saveDuplicateResults(
            makeDuplicateResults(), computedAt: Date(), forTargetID: target.id, minimumFileSize: minimumFileSize
        )
        await cache.removeAll()
        #expect(duplicateResultsFileURLs(in: cacheDirectory).isEmpty)
        #expect(await cache.totalSizeOnDisk() == 0)
    }

    // MARK: - Helpers

    private func duplicateResultsFileURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "nddup" }
    }

    private func makeDuplicateResults() -> DuplicateScanResults {
        let group = DuplicateGroup(
            id: "abc-100", fileSize: 100, nodeIDs: ["/x/a.bin", "/x/b.bin"]
        )
        return DuplicateScanResults(
            groups: [group], totalWastedBytes: 100, candidateCount: 2, unreadableCount: 0
        )
    }

    private func changeListFileURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "nddiff" }
    }

    private func makeFileStore(target: ScanTarget, files: [(String, Int64)]) -> FileTreeStore {
        let children = files.map { name, size in
            makeTestFileNode(id: target.id + "/" + name, name: name, size: size)
        }
        let root = makeTestDirectoryNode(id: target.id, name: target.displayName, children: children)
        return FileTreeStore(root: root, childrenByID: [root.id: children])
    }

    private func makeFileSnapshot(
        target: ScanTarget,
        files: [(String, Int64)],
        finishedAt: Date = Date()
    ) -> ScanSnapshot {
        let store = makeFileStore(target: target, files: files)
        return makeTestSnapshot(
            target: target, root: store.root, store: store, finishedAt: finishedAt
        )
    }

    private func makeEmptyList() -> ScanChangeList {
        let previous = makeFileStore(target: makeTestTarget("/x"), files: [("k.bin", 1)])
        let current = makeFileStore(target: makeTestTarget("/x"), files: [("k.bin", 1)])
        return ScanChangeList.build(current: current, previous: previous, entryLimit: 500)
    }

    private func makeTemporaryCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "NeodiskCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func cacheFileURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "ndscan" }
    }

    private func singleCacheFileURL(in directory: URL) -> URL? {
        let cacheFiles = cacheFileURLs(in: directory)
        return cacheFiles.count == 1 ? cacheFiles[0] : nil
    }

    /// Exercises every optional node field: symlinks, packages, synthetic
    /// nodes with IDs detached from their paths, auto-summarized directories,
    /// both file-identity kinds, hard links, size divergence, and warnings.
    private func makeRichSnapshot(rootPath: String) -> ScanSnapshot {
        let hardLinked = makeTestFileNode(
            id: "\(rootPath)/movie.mov",
            name: "movie.mov",
            size: 4096,
            unduplicatedAllocatedSize: 0,
            lastModified: Date(timeIntervalSinceReferenceDate: 700_000_000.25),
            fileIdentity: .fileSystem(device: 42, inode: 1_234_567),
            linkCount: 3
        )
        let sparse = FileNodeRecord(
            id: "\(rootPath)/sparse.bin",
            url: URL(filePath: "\(rootPath)/sparse.bin"),
            name: "sparse.bin",
            isDirectory: false,
            isSymbolicLink: false,
            allocatedSize: 512,
            logicalSize: 1_048_576,
            descendantFileCount: 1,
            lastModified: nil,
            fileIdentity: .resourceIdentifier(Data([1, 2, 3, 4, 5])),
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false,
            // Kept clone-family member: identity captured, private size
            // never fetched.
            cloneInfo: CloneInfo(device: 42, cloneID: 0xC10, refCount: 2)
        )
        let chargedClone = makeTestFileNode(
            id: "\(rootPath)/sparse copy.bin",
            name: "sparse copy.bin",
            size: 0,
            unduplicatedAllocatedSize: 512,
            cloneInfo: CloneInfo(device: 42, cloneID: 0xC10, refCount: 2, privateSize: 0)
        )
        let symlink = FileNodeRecord(
            id: "\(rootPath)/alias",
            url: URL(filePath: "\(rootPath)/alias"),
            name: "alias",
            isDirectory: false,
            isSymbolicLink: true,
            allocatedSize: 0,
            logicalSize: 0,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
        let synthetic = FileNodeRecord(
            id: "\(rootPath)/\u{0}system-data",
            url: URL(filePath: rootPath, directoryHint: .isDirectory),
            name: "System Data",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 2_000,
            logicalSize: 2_000,
            descendantFileCount: 0,
            lastModified: nil,
            isPackage: false,
            isAccessible: false,
            isSelfAccessible: false,
            isSynthetic: true,
            isAutoSummarized: false
        )
        let summarized = FileNodeRecord(
            id: "\(rootPath)/node_modules",
            url: URL(filePath: "\(rootPath)/node_modules", directoryHint: .isDirectory),
            name: "node_modules",
            isDirectory: true,
            isSymbolicLink: false,
            allocatedSize: 9_000,
            logicalSize: 9_000,
            descendantFileCount: 5_120,
            lastModified: Date(timeIntervalSinceReferenceDate: 690_000_000),
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: true
        )
        let packagedFile = makeTestFileNode(
            id: "\(rootPath)/Photos.app/binary",
            name: "binary",
            size: 300
        )
        let package = makeTestDirectoryNode(
            id: "\(rootPath)/Photos.app",
            name: "Photos.app",
            children: [packagedFile],
            isPackage: true
        )
        let restricted = makeTestDirectoryNode(
            id: "\(rootPath)/locked",
            name: "locked",
            children: [],
            isAccessible: false
        )
        let children = [hardLinked, sparse, chargedClone, symlink, synthetic, summarized, package, restricted]
        let root = makeTestDirectoryNode(
            id: rootPath,
            name: (rootPath as NSString).lastPathComponent,
            children: children
        )
        let store = FileTreeStore(root: root, childrenByID: [
            root.id: children,
            package.id: [packagedFile],
        ])
        let warnings = [
            ScanWarning(path: "\(rootPath)/locked", message: "Permission denied", category: .permissionDenied),
            ScanWarning(path: "\(rootPath)/flaky", message: "I/O error", category: .fileSystem),
        ]
        return makeTestSnapshot(target: makeTestTarget(rootPath), root: root, store: store, warnings: warnings)
    }

    private func expectEqualTrees(
        _ loaded: FileTreeStore,
        _ original: FileTreeStore,
        carriesCloneInfo: Bool = true
    ) {
        #expect(loaded.rootID == original.rootID)
        #expect(loaded.nodeCount == original.nodeCount)
        #expect(loaded.indexedNodeIDs() == original.indexedNodeIDs())
        for nodeID in original.indexedNodeIDs() {
            #expect(loaded.parent(of: nodeID)?.id == original.parent(of: nodeID)?.id)
        }

        for nodeID in original.indexedNodeIDs() {
            guard let loadedNode = loaded.node(id: nodeID), let originalNode = original.node(id: nodeID) else {
                Issue.record("Node \(nodeID) missing after round trip.")
                continue
            }
            #expect(loaded.children(of: nodeID).map(\.id) == original.children(of: nodeID).map(\.id))
            expectEqualNodes(loadedNode, originalNode, carriesCloneInfo: carriesCloneInfo)
        }
    }

    private func expectEqualNodes(
        _ loaded: FileNodeRecord,
        _ original: FileNodeRecord,
        carriesCloneInfo: Bool = true
    ) {
        #expect(loaded.id == original.id)
        #expect(loaded.url.path == original.url.path)
        #expect(loaded.name == original.name)
        #expect(loaded.isDirectory == original.isDirectory)
        #expect(loaded.isSymbolicLink == original.isSymbolicLink)
        #expect(loaded.allocatedSize == original.allocatedSize)
        #expect(loaded.unduplicatedAllocatedSize == original.unduplicatedAllocatedSize)
        #expect(loaded.logicalSize == original.logicalSize)
        #expect(loaded.descendantFileCount == original.descendantFileCount)
        #expect(loaded.lastModified == original.lastModified)
        #expect(loaded.fileIdentity == original.fileIdentity)
        #expect(loaded.linkCount == original.linkCount)
        #expect(loaded.isPackage == original.isPackage)
        #expect(loaded.isAccessible == original.isAccessible)
        #expect(loaded.isSelfAccessible == original.isSelfAccessible)
        #expect(loaded.isSynthetic == original.isSynthetic)
        #expect(loaded.isAutoSummarized == original.isAutoSummarized)
        #expect(loaded.cloneInfo == (carriesCloneInfo ? original.cloneInfo : nil))
    }
}
