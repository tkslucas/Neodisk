//
//  SnapshotPayloadCompression.swift
//  Neodisk
//
//  The node-payload codec behind snapshot format v2+. Each platform uses its
//  native fast streaming codec: LZFSE through the Compression framework on
//  Apple platforms, zstd through libzstd on Linux. Snapshots are a
//  machine-local cache, never exchanged between machines, so the two never
//  need to read each other's files; a foreign payload fails decoding as
//  corrupt data, which the cache treats as a miss.
//

import Foundation
#if canImport(Compression)
import Compression
#elseif canImport(CZstd)
import CZstd
#endif

extension ScanSnapshotCodec {
    #if canImport(Compression)
    /// LZFSE-compresses `payload` onto the end of `output` through
    /// `compression_stream`, in 1 MB output chunks. The bytes are identical
    /// to `NSData.compressed(using: .lzfse)` (the same raw LZFSE stream the
    /// decoder reads), but that API is several times slower on large
    /// payloads — ~8 s against ~1.6 s for a 109 MB, 1.67M-node payload —
    /// and it offers no cancellation point; this checks between chunks.
    static func appendCompressedPayload(_ payload: Data, to output: inout Data) throws {
        let chunkSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else {
            throw ScanSnapshotCacheError.corruptData("payload compression failed")
        }
        defer { compression_stream_destroy(&stream) }
        try payload.withUnsafeBytes { source in
            stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            stream.src_size = source.count
            while true {
                try Task.checkCancellation()
                stream.dst_ptr = buffer
                stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw ScanSnapshotCacheError.corruptData("payload compression failed")
                }
                output.append(buffer, count: chunkSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { return }
            }
        }
    }

    /// Bound untrusted output before allocating it. A streaming decoder also
    /// checks cancellation between chunks instead of retaining obsolete work.
    static func decompressPayload(_ compressed: Data, maximumBytes: Int = 2 * 1024 * 1024 * 1024) throws -> Data {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else {
            throw ScanSnapshotCacheError.corruptData("payload decompression failed")
        }
        defer { compression_stream_destroy(&stream) }
        return try compressed.withUnsafeBytes { source in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else {
                throw ScanSnapshotCacheError.corruptData("empty compressed payload")
            }
            stream.src_ptr = base
            stream.src_size = source.count
            var output = Data()
            while true {
                try Task.checkCancellation()
                stream.dst_ptr = buffer
                stream.dst_size = 64 * 1024
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = 64 * 1024 - stream.dst_size
                guard status != COMPRESSION_STATUS_ERROR, produced <= maximumBytes - output.count else {
                    throw ScanSnapshotCacheError.corruptData("invalid or oversized compressed payload")
                }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else {
                        throw ScanSnapshotCacheError.corruptData("trailing compressed payload bytes")
                    }
                    return output
                }
                guard produced > 0 else {
                    throw ScanSnapshotCacheError.corruptData("truncated compressed payload")
                }
            }
        }
    }

    #elseif canImport(CZstd)
    /// zstd level the Linux cache writes at: libzstd's own default, which
    /// compresses a 100 MB payload in a fraction of a second while matching
    /// LZFSE's ratio.
    private static let zstdCompressionLevel: Int32 = 3

    /// zstd-compresses `payload` onto the end of `output` as a single frame,
    /// in 1 MB output chunks with a cancellation check between them. The
    /// whole input is handed over on the first call, so the frame header
    /// records the content size the decoder uses to preallocate.
    static func appendCompressedPayload(_ payload: Data, to output: inout Data) throws {
        guard let context = ZSTD_createCCtx() else {
            throw ScanSnapshotCacheError.corruptData("payload compression failed")
        }
        defer { ZSTD_freeCCtx(context) }
        guard ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, zstdCompressionLevel)) == 0 else {
            throw ScanSnapshotCacheError.corruptData("payload compression failed")
        }
        let chunkSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        try payload.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            while true {
                try Task.checkCancellation()
                var chunk = ZSTD_outBuffer(dst: buffer, size: chunkSize, pos: 0)
                let remaining = ZSTD_compressStream2(context, &chunk, &input, ZSTD_e_end)
                guard ZSTD_isError(remaining) == 0 else {
                    throw ScanSnapshotCacheError.corruptData("payload compression failed")
                }
                output.append(buffer.assumingMemoryBound(to: UInt8.self), count: chunk.pos)
                if remaining == 0 { return }
            }
        }
    }

    /// Bound untrusted output before allocating it. A streaming decoder also
    /// checks cancellation between chunks instead of retaining obsolete work.
    static func decompressPayload(_ compressed: Data, maximumBytes: Int = 2 * 1024 * 1024 * 1024) throws -> Data {
        guard let context = ZSTD_createDCtx() else {
            throw ScanSnapshotCacheError.corruptData("payload decompression failed")
        }
        defer { ZSTD_freeDCtx(context) }
        let chunkSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        return try compressed.withUnsafeBytes { source in
            guard let base = source.baseAddress, source.count > 0 else {
                throw ScanSnapshotCacheError.corruptData("empty compressed payload")
            }
            var output = Data()
            // The declared size is untrusted: only a hint, and only within
            // the bound (the unknown/error sentinels are the top two values).
            let declaredSize = ZSTD_getFrameContentSize(base, source.count)
            if declaredSize < UInt64.max - 1, declaredSize <= UInt64(maximumBytes) {
                output.reserveCapacity(Int(declaredSize))
            }
            var input = ZSTD_inBuffer(src: base, size: source.count, pos: 0)
            while true {
                try Task.checkCancellation()
                var chunk = ZSTD_outBuffer(dst: buffer, size: chunkSize, pos: 0)
                let hint = ZSTD_decompressStream(context, &chunk, &input)
                guard ZSTD_isError(hint) == 0, chunk.pos <= maximumBytes - output.count else {
                    throw ScanSnapshotCacheError.corruptData("invalid or oversized compressed payload")
                }
                output.append(buffer.assumingMemoryBound(to: UInt8.self), count: chunk.pos)
                if hint == 0 {
                    // Frame complete.
                    guard input.pos == input.size else {
                        throw ScanSnapshotCacheError.corruptData("trailing compressed payload bytes")
                    }
                    return output
                }
                guard chunk.pos > 0 || input.pos < input.size else {
                    throw ScanSnapshotCacheError.corruptData("truncated compressed payload")
                }
            }
        }
    }
    #endif
}
