// Windows' snapshot payload codec: XPRESS with Huffman coding from the system Compression API (Cabinet.dll).
// Its buffer mode has no streaming decoder, so the payload is framed as independent 1 MB chunks and decoded one
// chunk at a time, keeping memory near the chunk size like the streaming decoders on the other platforms.
//
// Layout (little-endian): "XPH1", UInt64 decompressed size, then per chunk UInt32 decompressed size,
// UInt32 compressed size, compressed bytes.

#if os(Windows)
import Foundation
import WinSDK

nonisolated enum WindowsPayloadCodec {
    static let magic = Array("XPH1".utf8)
    static let chunkSize = 1 << 20
    private static let algorithm = DWORD(COMPRESS_ALGORITHM_XPRESS_HUFF)

    static func appendCompressed(_ payload: Data, to output: inout Data) throws {
        var compressor: COMPRESSOR_HANDLE?
        guard CreateCompressor(algorithm, nil, &compressor), let compressor else {
            throw ScanSnapshotCacheError.corruptData("payload compression failed")
        }
        defer { CloseCompressor(compressor) }

        output.append(contentsOf: magic)
        appendLittleEndian(UInt64(payload.count), to: &output)
        var scratch = [UInt8](repeating: 0, count: chunkSize + chunkSize / 8 + 4096)
        try payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < source.count {
                try Task.checkCancellation()
                let length = min(chunkSize, source.count - offset)
                var compressedLength: SIZE_T = 0
                var succeeded = scratch.withUnsafeMutableBytes { destination in
                    Compress(
                        compressor, source.baseAddress! + offset, SIZE_T(length),
                        destination.baseAddress, SIZE_T(destination.count), &compressedLength
                    )
                }
                if !succeeded, GetLastError() == DWORD(ERROR_INSUFFICIENT_BUFFER), Int(compressedLength) > scratch.count {
                    scratch = [UInt8](repeating: 0, count: Int(compressedLength))
                    succeeded = scratch.withUnsafeMutableBytes { destination in
                        Compress(
                            compressor, source.baseAddress! + offset, SIZE_T(length),
                            destination.baseAddress, SIZE_T(destination.count), &compressedLength
                        )
                    }
                }
                guard succeeded else {
                    throw ScanSnapshotCacheError.corruptData("payload compression failed")
                }
                appendLittleEndian(UInt32(length), to: &output)
                appendLittleEndian(UInt32(compressedLength), to: &output)
                output.append(contentsOf: scratch[..<Int(compressedLength)])
                offset += length
            }
        }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
    }

    /// Hands out a framed payload's bytes, decoding one chunk at a time.
    final class Decoder {
        /// From the header; already checked against the caller's limit.
        let declaredSize: Int
        private(set) var isFinished = false
        private let compressed: Data
        private let decompressor: DECOMPRESSOR_HANDLE
        private var inputOffset: Int
        private var chunk: [UInt8] = []
        private var chunkOffset = 0
        private var decodedCount = 0

        init(compressed: Data, maximumBytes: Int) throws {
            let headerLength = WindowsPayloadCodec.magic.count + 8
            guard compressed.count >= headerLength,
                  Array(compressed.prefix(WindowsPayloadCodec.magic.count)) == WindowsPayloadCodec.magic else {
                throw ScanSnapshotCacheError.corruptData("invalid compressed payload")
            }
            let declared = compressed.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: WindowsPayloadCodec.magic.count, as: UInt64.self))
            }
            guard declared <= UInt64(maximumBytes) else {
                throw ScanSnapshotCacheError.corruptData("invalid or oversized compressed payload")
            }
            var handle: DECOMPRESSOR_HANDLE?
            guard CreateDecompressor(WindowsPayloadCodec.algorithm, nil, &handle), let handle else {
                throw ScanSnapshotCacheError.corruptData("payload decompression failed")
            }
            self.compressed = compressed
            declaredSize = Int(declared)
            decompressor = handle
            inputOffset = headerLength
        }

        deinit {
            CloseDecompressor(decompressor)
        }

        /// Up to `count` bytes; 0 only at the end.
        func read(into destination: UnsafeMutableRawPointer, count: Int) throws -> Int {
            if chunkOffset == chunk.count {
                guard try decodeNextChunk() else {
                    guard decodedCount == declaredSize else {
                        throw ScanSnapshotCacheError.corruptData("truncated compressed payload")
                    }
                    isFinished = true
                    return 0
                }
            }
            let copied = min(count, chunk.count - chunkOffset)
            chunk.withUnsafeBytes { raw in
                destination.copyMemory(from: raw.baseAddress! + chunkOffset, byteCount: copied)
            }
            chunkOffset += copied
            if chunkOffset == chunk.count, inputOffset == compressed.count, decodedCount == declaredSize {
                isFinished = true
            }
            return copied
        }

        private func decodeNextChunk() throws -> Bool {
            guard inputOffset < compressed.count else { return false }
            guard compressed.count - inputOffset >= 8 else {
                throw ScanSnapshotCacheError.corruptData("truncated compressed payload")
            }
            let (rawLength, compressedLength) = compressed.withUnsafeBytes { raw in
                (
                    Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: inputOffset, as: UInt32.self))),
                    Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: inputOffset + 4, as: UInt32.self)))
                )
            }
            inputOffset += 8
            guard rawLength > 0, rawLength <= WindowsPayloadCodec.chunkSize,
                  rawLength <= declaredSize - decodedCount,
                  compressedLength <= compressed.count - inputOffset else {
                throw ScanSnapshotCacheError.corruptData("invalid or oversized compressed payload")
            }
            if chunk.count != rawLength {
                chunk = [UInt8](repeating: 0, count: rawLength)
            }
            var produced: SIZE_T = 0
            let succeeded = compressed.withUnsafeBytes { source in
                chunk.withUnsafeMutableBytes { output in
                    Decompress(
                        decompressor, source.baseAddress! + inputOffset, SIZE_T(compressedLength),
                        output.baseAddress, SIZE_T(rawLength), &produced
                    )
                }
            }
            guard succeeded, Int(produced) == rawLength else {
                throw ScanSnapshotCacheError.corruptData("invalid compressed payload")
            }
            inputOffset += compressedLength
            decodedCount += rawLength
            chunkOffset = 0
            return true
        }
    }
}
#endif
