// Per-file tier digests persisted across runs, validated by size, mtime and inode, so a re-scan only
// re-reads changed files. A tool that rewrites content but restores mtime defeats it (accepted trade).

import Foundation

public final class DuplicateHashCache: @unchecked Sendable {
    /// Cached per tier, so a file that only reached the head tier still saves that read next time.
    public enum Tier: String, Codable, Sendable {
        case head
        case prefix
        case full
    }

    /// mtime keeps nanoseconds (APFS). Size is part of correctness: the tiers' read lengths depend on it.
    public struct FileStamp: Codable, Equatable, Sendable {
        public let size: Int64
        public let modifiedAtNanoseconds: Int64
        public let inode: UInt64

        public init(size: Int64, modifiedAtNanoseconds: Int64, inode: UInt64) {
            self.size = size
            self.modifiedAtNanoseconds = modifiedAtNanoseconds
            self.inode = inode
        }
    }

    struct Entry: Codable, Sendable {
        var stamp: FileStamp
        var headDigest: String?
        var prefixDigest: String?
        var fullDigest: String?
        /// Recency for save-time trimming, seconds since the reference date.
        var lastUsedAt: Double

        func digest(for tier: Tier) -> String? {
            switch tier {
            case .head: return headDigest
            case .prefix: return prefixDigest
            case .full: return fullDigest
            }
        }

        mutating func setDigest(_ digest: String, for tier: Tier) {
            switch tier {
            case .head: headDigest = digest
            case .prefix: prefixDigest = digest
            case .full: fullDigest = digest
            }
        }
    }

    private struct Payload: Codable {
        var hashFormatVersion: Int
        var entries: [String: Entry]
    }

    /// Bump when any tier's read shape changes (lengths, tail sampling, or
    /// the digest algorithm): older caches are then discarded wholesale.
    public static let currentHashFormatVersion = 1
    /// Only size-colliding files that reached hashing land here; the cap bounds the pathological case.
    public static let maxPersistedEntries = 100_000

    private let lock = NSLock()
    private var entries: [String: Entry]
    private var dirty = false

    public init() {
        entries = [:]
    }

    /// Decodes a persisted cache; a corrupt blob or a different hash format
    /// just starts empty — this is a cache, missing is never an error.
    public init(decoding data: Data) {
        if let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.hashFormatVersion == Self.currentHashFormatVersion {
            entries = payload.entries
        } else {
            entries = [:]
        }
    }

    /// Whether anything was stored or freshened since load — a save with a
    /// clean cache would be a pointless rewrite of the whole file.
    public var isDirty: Bool {
        lock.withLock { dirty }
    }

    public var entryCount: Int {
        lock.withLock { entries.count }
    }

    /// The digest cached for `tier`, provided the file still matches
    /// `stamp`; a hit refreshes the entry's recency.
    public func cachedDigest(for path: String, tier: Tier, stamp: FileStamp) -> String? {
        lock.withLock {
            guard var entry = entries[path], entry.stamp == stamp,
                  let digest = entry.digest(for: tier) else { return nil }
            entry.lastUsedAt = Date().timeIntervalSinceReferenceDate
            entries[path] = entry
            dirty = true
            return digest
        }
    }

    /// A stamp change replaces the whole entry: no old tier digest can outlive the bytes it described.
    public func storeDigest(_ digest: String, for path: String, tier: Tier, stamp: FileStamp) {
        lock.withLock {
            var entry: Entry
            if let existing = entries[path], existing.stamp == stamp {
                entry = existing
            } else {
                entry = Entry(stamp: stamp, lastUsedAt: 0)
            }
            entry.setDigest(digest, for: tier)
            entry.lastUsedAt = Date().timeIntervalSinceReferenceDate
            entries[path] = entry
            dirty = true
        }
    }

    /// Encodes for persistence, trimming the least recently used overflow
    /// past `maxPersistedEntries`.
    public func encodedTrimmed() -> Data? {
        let snapshot: [String: Entry] = lock.withLock {
            if entries.count <= Self.maxPersistedEntries { return entries }
            let kept = entries.sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }
                .prefix(Self.maxPersistedEntries)
            return Dictionary(uniqueKeysWithValues: Array(kept))
        }
        return try? JSONEncoder().encode(Payload(
            hashFormatVersion: Self.currentHashFormatVersion,
            entries: snapshot
        ))
    }
}
