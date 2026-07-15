import Foundation
import Testing
@testable import NeodiskKit

@Suite struct DuplicateHashCacheTests {
    private func stamp(size: Int64 = 100, mtime: Int64 = 1_000, inode: UInt64 = 42) -> DuplicateHashCache.FileStamp {
        DuplicateHashCache.FileStamp(size: size, modifiedAtNanoseconds: mtime, inode: inode)
    }

    @Test func hitRequiresMatchingStamp() {
        let cache = DuplicateHashCache()
        cache.storeDigest("abc", for: "/a", tier: .head, stamp: stamp())

        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: stamp()) == "abc")
        // Any drifted stamp field is a miss.
        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: stamp(size: 101)) == nil)
        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: stamp(mtime: 1_001)) == nil)
        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: stamp(inode: 43)) == nil)
        // Other tiers were never stored.
        #expect(cache.cachedDigest(for: "/a", tier: .full, stamp: stamp()) == nil)
    }

    @Test func tiersAccumulatePerPathAndStampChangeReplacesAll() {
        let cache = DuplicateHashCache()
        cache.storeDigest("h", for: "/a", tier: .head, stamp: stamp())
        cache.storeDigest("p", for: "/a", tier: .prefix, stamp: stamp())
        cache.storeDigest("f", for: "/a", tier: .full, stamp: stamp())

        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: stamp()) == "h")
        #expect(cache.cachedDigest(for: "/a", tier: .prefix, stamp: stamp()) == "p")
        #expect(cache.cachedDigest(for: "/a", tier: .full, stamp: stamp()) == "f")

        // The file changed: storing under the new stamp must drop every old
        // tier digest, not just the one being replaced.
        let changed = stamp(mtime: 2_000)
        cache.storeDigest("h2", for: "/a", tier: .head, stamp: changed)
        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: changed) == "h2")
        #expect(cache.cachedDigest(for: "/a", tier: .prefix, stamp: changed) == nil)
        #expect(cache.cachedDigest(for: "/a", tier: .full, stamp: changed) == nil)
        #expect(cache.cachedDigest(for: "/a", tier: .head, stamp: stamp()) == nil)
    }

    @Test func persistsThroughEncodeDecode() throws {
        let cache = DuplicateHashCache()
        cache.storeDigest("h", for: "/a", tier: .head, stamp: stamp())
        cache.storeDigest("f", for: "/b", tier: .full, stamp: stamp(inode: 7))

        let data = try #require(cache.encodedTrimmed())
        let decoded = DuplicateHashCache(decoding: data)
        // A fresh decode starts clean; only new work (including hits, which
        // freshen recency) should trigger a save.
        #expect(!decoded.isDirty)
        #expect(decoded.entryCount == 2)
        #expect(decoded.cachedDigest(for: "/a", tier: .head, stamp: stamp()) == "h")
        #expect(decoded.cachedDigest(for: "/b", tier: .full, stamp: stamp(inode: 7)) == "f")
    }

    @Test func corruptOrForeignVersionDecodesEmpty() {
        #expect(DuplicateHashCache(decoding: Data("junk".utf8)).entryCount == 0)

        let foreign = """
        {"hashFormatVersion": \(DuplicateHashCache.currentHashFormatVersion + 1), "entries": {}}
        """
        #expect(DuplicateHashCache(decoding: Data(foreign.utf8)).entryCount == 0)
    }

    @Test func dirtyTracksStoresAndHits() {
        let cache = DuplicateHashCache()
        #expect(!cache.isDirty)
        cache.storeDigest("h", for: "/a", tier: .head, stamp: stamp())
        #expect(cache.isDirty)

        let reloaded = DuplicateHashCache(decoding: cache.encodedTrimmed() ?? Data())
        #expect(!reloaded.isDirty)
        // A pure hit freshens recency, which is worth persisting too.
        _ = reloaded.cachedDigest(for: "/a", tier: .head, stamp: stamp())
        #expect(reloaded.isDirty)
    }

    @Test func saveTrimsLeastRecentlyUsedOverflow() throws {
        let cache = DuplicateHashCache()
        for index in 0...DuplicateHashCache.maxPersistedEntries {
            cache.storeDigest("d", for: "/file-\(index)", tier: .head, stamp: stamp())
        }
        // Freshen the very first entry so the trim drops some other one.
        _ = cache.cachedDigest(for: "/file-0", tier: .head, stamp: stamp())

        let data = try #require(cache.encodedTrimmed())
        let decoded = DuplicateHashCache(decoding: data)
        #expect(decoded.entryCount == DuplicateHashCache.maxPersistedEntries)
        #expect(decoded.cachedDigest(for: "/file-0", tier: .head, stamp: stamp()) == "d")
    }
}
