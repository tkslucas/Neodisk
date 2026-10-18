// Node-payload codec: LZFSE on Apple platforms, zstd on Linux. Snapshots are a machine-local cache, so a
// foreign payload just fails as corrupt, which the cache treats as a miss.

import Foundation
#if canImport(Compression)
import Compression
#elseif canImport(CZstd)
import CZstd
#endif

extension ScanSnapshotCodec {
    #if canImport(Compression)
    /// Same bytes as `NSData.compressed(using: .lzfse)`, which is ~5x slower on large payloads and can't be
    /// cancelled; this checks between 1 MB chunks.
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


    #elseif canImport(CZstd)
    /// libzstd's default: a fraction of a second for 100 MB at LZFSE's ratio.
    private static let zstdCompressionLevel: Int32 = 3

    /// The whole input goes in on the first call so the frame header records the size the decoder preallocates.
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

    #endif
}

extension ScanSnapshotCodec {
    /// The whole payload in one buffer (the decoder streams it instead; see
    /// SnapshotPayloadStream.swift). Output is bounded before it's allocated.
    static func decompressPayload(_ compressed: Data, maximumBytes: Int = 2 * 1024 * 1024 * 1024) throws -> Data {
        try PayloadDecompressor(compressed: compressed, maximumBytes: maximumBytes).readAll()
    }
}
