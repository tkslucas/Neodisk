//
//  TokenCountService.swift
//  Neodisk
//

import Darwin
import Foundation

/// Token counts for the text files of one tree. Files missing from
/// `tokensByID` were skipped: binary, unreadable, or cloud-only.
public struct TokenTally: Sendable {
    public let tokensByID: [String: Int]
    /// Files larger than the read cap, extrapolated from their first bytes.
    public let sampledIDs: Set<String>
    public let nonTextFileCount: Int

    public var textFileCount: Int { tokensByID.count }

    public init(tokensByID: [String: Int], sampledIDs: Set<String> = [], nonTextFileCount: Int = 0) {
        self.tokensByID = tokensByID
        self.sampledIDs = sampledIDs
        self.nonTextFileCount = nonTextFileCount
    }
}

/// Per-file results kept across scans, so a rescan or metric toggle only
/// rereads files whose size or modification date changed.
public final class TokenCountCache: @unchecked Sendable {
    struct Entry {
        let size: Int64
        let modified: Date
        /// nil: not text.
        let tokens: Int?
        let sampled: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    func entry(for node: FileNodeRecord) -> Entry? {
        guard let modified = node.lastModified else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[node.id],
              entry.size == node.logicalSize, entry.modified == modified else { return nil }
        return entry
    }

    func store(_ results: [(id: String, entry: Entry)]) {
        lock.lock()
        defer { lock.unlock() }
        for result in results {
            entries[result.id] = result.entry
        }
    }
}

public enum TokenCountService {
    /// Files past this are counted from their first bytes and extrapolated.
    static let maxReadBytes = 4 << 20

    /// Extensions that are never text; skipped without opening the file.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns", "psd",
        "raw", "cr2", "nef", "dng", "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "aac",
        "wav", "aif", "aiff", "flac", "ogg", "opus", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z",
        "rar", "tar", "dmg", "iso", "pkg", "img", "dylib", "so", "a", "o", "dll", "exe", "bin",
        "class", "jar", "pyc", "wasm", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key",
        "pages", "numbers", "sqlite", "db", "realm", "ttf", "otf", "woff", "woff2", "car", "nib",
        "mlmodel", "pt", "safetensors", "onnx", "gguf", "npy", "parquet", "pack", "idx",
    ]

    /// Whether a node is worth opening: a regular, local, readable file.
    public static func isCandidate(_ node: FileNodeRecord) -> Bool {
        !node.isDirectory && !node.isSymbolicLink && !node.isSynthetic && !node.isDataless
            && node.isSelfAccessible && node.logicalSize > 0
            && !binaryExtensions.contains(node.pathExtension.lowercased())
    }

    /// Reads every candidate file under `store`, in parallel. Blocking: call
    /// off the main actor. Returns nil when cancelled.
    public static func count(
        store: FileTreeStore,
        counter: some TokenCounter = HeuristicTokenCounter(),
        cache: TokenCountCache = TokenCountCache(),
        progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) -> TokenTally? {
        let candidates = store.allNodes.filter(isCandidate)
        let total = candidates.count
        let workerCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let state = SharedState(workerCount: workerCount)
        progress(0, total)

        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            var buffer = [UInt8](repeating: 0, count: maxReadBytes)
            var results: [(id: String, entry: TokenCountCache.Entry)] = []
            while !isCancelled(), let range = state.nextBatch(total: total) {
                for node in candidates[range] {
                    if let cached = cache.entry(for: node) {
                        results.append((node.id, cached))
                    } else if let entry = measure(node, counter: counter, buffer: &buffer) {
                        results.append((node.id, entry))
                    }
                }
                progress(state.finish(range.count), total)
            }
            state.store(results, worker: worker)
        }
        guard !isCancelled() else { return nil }

        var tokensByID: [String: Int] = [:]
        var sampledIDs: Set<String> = []
        var nonTextFileCount = 0
        for results in state.results {
            cache.store(results)
            for (id, entry) in results {
                if let tokens = entry.tokens {
                    tokensByID[id] = tokens
                    if entry.sampled { sampledIDs.insert(id) }
                } else {
                    nonTextFileCount += 1
                }
            }
        }
        return TokenTally(tokensByID: tokensByID, sampledIDs: sampledIDs, nonTextFileCount: nonTextFileCount)
    }

    private static func measure(
        _ node: FileNodeRecord,
        counter: some TokenCounter,
        buffer: inout [UInt8]
    ) -> TokenCountCache.Entry? {
        guard let modified = node.lastModified else { return nil }
        let read = readPrefix(of: node.path, into: &buffer)
        guard read >= 0 else { return nil }
        let tokens = buffer.withUnsafeBytes { all -> Int? in
            let bytes = UnsafeRawBufferPointer(rebasing: all[..<read])
            return countText(bytes, counter: counter)
        }
        let sampled = Int64(read) < node.logicalSize
        let scaled = tokens.map { sampled && read > 0 ? Int(Double($0) * Double(node.logicalSize) / Double(read)) : $0 }
        return .init(size: node.logicalSize, modified: modified, tokens: scaled, sampled: sampled && tokens != nil)
    }

    /// Tokens in `bytes`, or nil when they don't look like text.
    static func countText(_ bytes: UnsafeRawBufferPointer, counter: some TokenCounter) -> Int? {
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(bytes: bytes.dropFirst(2), encoding: encoding) else { return nil }
            return counter.countTokens(in: text)
        }
        guard looksLikeText(UnsafeRawBufferPointer(rebasing: bytes.prefix(8192))) else { return nil }
        return counter.countTokens(in: bytes)
    }

    /// No NUL bytes and few control characters.
    static func looksLikeText(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var control = 0
        for byte in bytes {
            if byte == 0 { return false }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B {
                control += 1
            }
        }
        return control * 20 <= bytes.count
    }

    /// Reads up to the buffer's size; -1 on error or for cloud-only files,
    /// which would otherwise download on open.
    private static func readPrefix(of path: String, into buffer: inout [UInt8]) -> Int {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return -1 }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return -1 }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var total = 0
        let capacity = buffer.count
        while total < capacity {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, capacity - total) }
            if n < 0 { return -1 }
            if n == 0 { break }
            total += n
        }
        return total
    }
}

private final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var done = 0
    private(set) var results: [[(id: String, entry: TokenCountCache.Entry)]]

    init(workerCount: Int) {
        results = Array(repeating: [], count: workerCount)
    }

    func nextBatch(total: Int) -> Range<Int>? {
        lock.lock()
        defer { lock.unlock() }
        guard next < total else { return nil }
        let range = next..<min(total, next + 32)
        next = range.upperBound
        return range
    }

    func store(_ workerResults: [(id: String, entry: TokenCountCache.Entry)], worker: Int) {
        lock.lock()
        defer { lock.unlock() }
        results[worker] = workerResults
    }

    func finish(_ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        done += count
        return done
    }
}
