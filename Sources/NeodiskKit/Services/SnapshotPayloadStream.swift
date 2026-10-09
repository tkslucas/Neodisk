//
//  SnapshotPayloadStream.swift
//  Neodisk
//
//  Decompresses a snapshot's node payload while it's parsed, instead of
//  into one buffer first: a millions-of-nodes payload is hundreds of
//  megabytes decompressed, and holding it next to the tree it becomes was
//  the peak of opening a large saved scan. PayloadDecompressor produces the
//  bytes on demand (LZFSE on Apple platforms, zstd on Linux — see
//  SnapshotPayloadCompression.swift), and StreamingPayloadReader parses
//  them through a small refilling window with the same reads as
//  PayloadReader.
//

import Foundation
#if canImport(Compression)
import Compression
#elseif canImport(CZstd)
import CZstd
#endif

/// The reads the node-payload decoder needs, over either a whole buffer
/// (PayloadReader) or a stream (StreamingPayloadReader).
nonisolated protocol PayloadReading: LittleEndianByteReading {
    mutating func readString() throws -> String
}

extension PayloadReader: PayloadReading {}

/// Where a streaming payload reader gets its bytes.
nonisolated protocol PayloadByteSource: AnyObject {
    var maximumBytes: Int { get }
    var expectedSizeBound: Int { get }
    var producedCount: Int { get }
    var isFinished: Bool { get }
    func read(into destination: UnsafeMutableRawPointer, count: Int) throws -> Int
}

/// Produces a compressed payload's bytes on demand.
nonisolated final class PayloadDecompressor: PayloadByteSource {
    /// The largest payload accepted.
    let maximumBytes: Int
    /// Decompressed size, when the stream declares it (zstd frames do).
    let declaredSize: Int?
    /// What the payload is expected to decompress to at most: the declared
    /// size, or else a generous multiple of the compressed size. Only an
    /// estimate for the decoder's plausibility checks — output past it is
    /// still accepted up to `maximumBytes`.
    let expectedSizeBound: Int
    private(set) var producedCount = 0
    private(set) var isFinished = false
    private let compressed: Data

    #if canImport(Compression)
    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer(bitPattern: 1)!, dst_size: 0,
        src_ptr: UnsafePointer(bitPattern: 1)!, src_size: 0, state: nil
    )
    private var consumedCount = 0
    #elseif canImport(CZstd)
    private let context: OpaquePointer
    private var inputPosition = 0
    #endif

    /// LZFSE doesn't record the decompressed size; payloads compress about
    /// 6.5×, so this many times the compressed size bounds them generously.
    static let undeclaredExpansionBound = 64

    init(compressed: Data, maximumBytes: Int = 2 * 1024 * 1024 * 1024) throws {
        guard !compressed.isEmpty else {
            throw ScanSnapshotCacheError.corruptData("empty compressed payload")
        }
        self.compressed = compressed
        #if canImport(Compression)
        declaredSize = nil
        self.maximumBytes = maximumBytes
        let (expanded, overflow) = compressed.count.multipliedReportingOverflow(by: Self.undeclaredExpansionBound)
        expectedSizeBound = overflow ? maximumBytes : min(maximumBytes, expanded)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else {
            throw ScanSnapshotCacheError.corruptData("payload decompression failed")
        }
        #elseif canImport(CZstd)
        guard let context = ZSTD_createDCtx() else {
            throw ScanSnapshotCacheError.corruptData("payload decompression failed")
        }
        self.context = context
        // The declared size is untrusted: only a hint, and only within the
        // bound (the unknown/error sentinels are the top two values).
        let declared = compressed.withUnsafeBytes { source in
            ZSTD_getFrameContentSize(source.baseAddress, source.count)
        }
        if declared < UInt64.max - 1, declared <= UInt64(maximumBytes) {
            declaredSize = Int(declared)
            self.maximumBytes = Int(declared)
            expectedSizeBound = Int(declared)
        } else {
            declaredSize = nil
            self.maximumBytes = maximumBytes
            expectedSizeBound = maximumBytes
        }
        #endif
    }

    deinit {
        #if canImport(Compression)
        compression_stream_destroy(&stream)
        #elseif canImport(CZstd)
        ZSTD_freeDCtx(context)
        #endif
    }

    /// Writes up to `count` bytes to `destination` and returns how many; 0
    /// once the payload is complete. Throws on corrupt, truncated, or
    /// oversized input, and on cancellation.
    /// Time spent decompressing, with NEODISK_SCAN_TIMING (decode reports it).
    private(set) var decompressNanoseconds: UInt64 = 0

    func read(into destination: UnsafeMutableRawPointer, count: Int) throws -> Int {
        guard !isFinished, count > 0 else { return 0 }
        try Task.checkCancellation()
        let since = ScanTiming.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if ScanTiming.isEnabled { decompressNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- since }
        }
        #if canImport(Compression)
        return try compressed.withUnsafeBytes { source in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            stream.src_ptr = base + consumedCount
            stream.src_size = source.count - consumedCount
            stream.dst_ptr = destination.assumingMemoryBound(to: UInt8.self)
            stream.dst_size = count
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            consumedCount = source.count - stream.src_size
            let produced = count - stream.dst_size
            guard status != COMPRESSION_STATUS_ERROR, produced <= maximumBytes - producedCount else {
                throw ScanSnapshotCacheError.corruptData("invalid or oversized compressed payload")
            }
            producedCount += produced
            if status == COMPRESSION_STATUS_END {
                guard stream.src_size == 0 else {
                    throw ScanSnapshotCacheError.corruptData("trailing compressed payload bytes")
                }
                isFinished = true
            } else if produced == 0 {
                throw ScanSnapshotCacheError.corruptData("truncated compressed payload")
            }
            return produced
        }
        #elseif canImport(CZstd)
        return try compressed.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: inputPosition)
            var output = ZSTD_outBuffer(dst: destination, size: count, pos: 0)
            while output.pos < output.size {
                let progress = (input.pos, output.pos)
                let hint = ZSTD_decompressStream(context, &output, &input)
                guard ZSTD_isError(hint) == 0, output.pos <= maximumBytes - producedCount else {
                    throw ScanSnapshotCacheError.corruptData("invalid or oversized compressed payload")
                }
                if hint == 0 {
                    // Frame complete.
                    guard input.pos == input.size else {
                        throw ScanSnapshotCacheError.corruptData("trailing compressed payload bytes")
                    }
                    isFinished = true
                    break
                }
                // Out of input with the frame unfinished and nothing left
                // to flush.
                guard input.pos != progress.0 || output.pos != progress.1 else {
                    throw ScanSnapshotCacheError.corruptData("truncated compressed payload")
                }
            }
            inputPosition = input.pos
            producedCount += output.pos
            return output.pos
        }
        #else
        throw ScanSnapshotCacheError.corruptData("payload compression unavailable")
        #endif
    }

    /// The whole payload in one buffer.
    func readAll() throws -> Data {
        var output = Data()
        if let declaredSize {
            output.reserveCapacity(declaredSize)
        }
        let chunkSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while case let produced = try read(into: buffer, count: chunkSize), produced > 0 {
            output.append(buffer.assumingMemoryBound(to: UInt8.self), count: produced)
        }
        return output
    }
}

/// Parses a compressed payload as it decompresses, through a window that
/// refills from the decompressor: memory stays at the window's size
/// instead of the whole payload's.
nonisolated final class StreamingPayloadReader: PayloadReading {
    private let source: any PayloadByteSource
    private var window: UnsafeMutableRawPointer
    private var capacity: Int
    private var start = 0
    private var end = 0

    init(source: any PayloadByteSource, windowSize: Int = 4 << 20) {
        self.source = source
        capacity = windowSize
        window = UnsafeMutableRawPointer.allocate(byteCount: windowSize, alignment: 16)
    }

    deinit {
        window.deallocate()
    }

    /// Buffered bytes plus what the stream may still produce: exact when
    /// the stream declares its size, an estimate otherwise (falling back to
    /// the hard limit once output passes the estimate).
    var remainingByteCount: Int {
        let produced = source.producedCount
        let bound = produced < source.expectedSizeBound ? source.expectedSizeBound : source.maximumBytes
        return (end - start) + max(0, bound - produced)
    }

    var isAtEnd: Bool {
        guard end == start else { return false }
        if !source.isFinished {
            _ = try? ensure(1)
        }
        return end == start && source.isFinished
    }

    /// Makes `count` contiguous bytes available at `start`; false when the
    /// payload ends first.
    private func ensure(_ count: Int) throws -> Bool {
        if end - start >= count { return true }
        if start > 0 {
            if end > start {
                window.copyMemory(from: window + start, byteCount: end - start)
            }
            end -= start
            start = 0
        }
        if count > capacity {
            var grown = capacity
            while grown < count { grown <<= 1 }
            let resized = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 16)
            resized.copyMemory(from: window, byteCount: end)
            window.deallocate()
            window = resized
            capacity = grown
        }
        while end < count {
            let produced = try source.read(into: window + end, count: capacity - end)
            if produced == 0 { break }
            end += produced
        }
        return end - start >= count
    }

    private func take(_ count: Int) throws -> UnsafeRawPointer {
        guard count >= 0, try ensure(count) else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { start += count }
        return UnsafeRawPointer(window + start)
    }

    func readUInt8() throws -> UInt8 {
        try take(1).load(as: UInt8.self)
    }

    func readString() throws -> String {
        let count = Int(UInt32(littleEndian: try load(UInt32.self)))
        let bytes = try take(count)
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func readBytes(count: Int) throws -> Data {
        Data(bytes: try take(count), count: count)
    }

    func load<T>(_ type: T.Type) throws -> T {
        try take(MemoryLayout<T>.size).loadUnaligned(as: type)
    }
}

/// Decompresses ahead on its own thread, a few chunks at a time, while the
/// reader parses what is already out: decoding a snapshot was decompress
/// then parse, one after the other, on one thread. Errors surface on the
/// read that would have hit them; cancellation is checked on the reader's
/// side; the thread stops when the source ends, fails, or this is released.
nonisolated final class PrefetchingPayloadSource: PayloadByteSource, @unchecked Sendable {
    private let source: PayloadDecompressor
    let maximumBytes: Int
    let expectedSizeBound: Int
    private(set) var producedCount = 0

    private let condition = NSCondition()
    private var ready: [Data] = []
    private var sourceEnded = false
    private var sourceError: Error?
    private var stopped = false
    private let depth: Int

    private var current = Data()
    private var currentOffset = 0

    init(source: PayloadDecompressor, chunkSize: Int = 1 << 20, depth: Int = 4) {
        self.source = source
        self.maximumBytes = source.maximumBytes
        self.expectedSizeBound = source.expectedSizeBound
        self.depth = depth
        let thread = Thread { [self] in produce(chunkSize: chunkSize) }
        thread.qualityOfService = .userInitiated
        thread.name = "com.neodisk.snapshot-decompress"
        thread.start()
    }

    deinit {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    private func produce(chunkSize: Int) {
        while true {
            var chunk = Data(count: chunkSize)
            var filled = 0
            var failure: Error?
            chunk.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                do {
                    while filled < chunkSize {
                        let produced = try source.read(into: base + filled, count: chunkSize - filled)
                        if produced == 0 { break }
                        filled += produced
                    }
                } catch {
                    failure = error
                }
            }
            chunk.count = filled
            condition.lock()
            while ready.count >= depth && !stopped {
                condition.wait()
            }
            if stopped {
                condition.unlock()
                return
            }
            if filled > 0 { ready.append(chunk) }
            if let failure {
                sourceError = failure
            }
            let ended = failure != nil || source.isFinished || filled == 0
            if ended { sourceEnded = true }
            condition.broadcast()
            condition.unlock()
            if ended { return }
        }
    }

    var isFinished: Bool {
        guard currentOffset >= current.count else { return false }
        condition.lock()
        defer { condition.unlock() }
        return ready.isEmpty && sourceEnded && sourceError == nil
    }

    func read(into destination: UnsafeMutableRawPointer, count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        try Task.checkCancellation()
        if currentOffset >= current.count {
            condition.lock()
            while ready.isEmpty && !sourceEnded {
                condition.wait()
            }
            if ready.isEmpty {
                let error = sourceError
                condition.unlock()
                if let error { throw error }
                return 0
            }
            current = ready.removeFirst()
            currentOffset = 0
            condition.broadcast()
            condition.unlock()
        }
        let available = current.count - currentOffset
        let copied = min(available, count)
        current.withUnsafeBytes { raw in
            destination.copyMemory(from: raw.baseAddress! + currentOffset, byteCount: copied)
        }
        currentOffset += copied
        producedCount += copied
        return copied
    }
}
