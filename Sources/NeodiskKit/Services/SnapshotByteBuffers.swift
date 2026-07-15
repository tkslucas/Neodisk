//
//  SnapshotByteBuffers.swift
//  Neodisk
//
//  Little-endian byte buffers behind ScanSnapshotCodec: ByteWriter for
//  encoding, ByteReader over Data for headers and metadata, and the
//  raw-pointer PayloadReader for the hot node-payload decode.
//

import Foundation


/// The little-endian decode surface PayloadReader and ByteReader share: each
/// type provides the bounds-checked primitives for its backing storage (raw
/// pointer vs Data), and the fixed-width reads are derived here once so the
/// two decoders cannot drift.
nonisolated protocol LittleEndianByteReading {
    var isAtEnd: Bool { get }
    var remainingByteCount: Int { get }
    mutating func readUInt8() throws -> UInt8
    mutating func readBytes(count: Int) throws -> Data
    mutating func load<T>(_ type: T.Type) throws -> T
}

extension LittleEndianByteReading {
    mutating func readUInt16() throws -> UInt16 {
        UInt16(littleEndian: try load(UInt16.self))
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(littleEndian: try load(UInt32.self))
    }

    mutating func readUInt64() throws -> UInt64 {
        UInt64(littleEndian: try load(UInt64.self))
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }
}

/// Raw-pointer counterpart of ByteReader for the (possibly decompressed)
/// node payload: no per-read Data subscripting, and strings decode straight
/// from the buffer. Only valid inside the payload's withUnsafeBytes scope.
nonisolated struct PayloadReader: LittleEndianByteReading {
    let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var isAtEnd: Bool {
        offset == buffer.count
    }

    var remainingByteCount: Int {
        buffer.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingByteCount >= 1 else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt32())
        guard remainingByteCount >= count else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += count }
        return String(
            decoding: UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + count)]),
            as: UTF8.self
        )
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, remainingByteCount >= count else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += count }
        return Data(buffer[offset..<(offset + count)])
    }

    mutating func load<T>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingByteCount >= size else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += size }
        return buffer.loadUnaligned(fromByteOffset: offset, as: type)
    }
}

// MARK: - Little-endian byte buffers

nonisolated struct ByteWriter {
    var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt32(bytes.count))
        data.append(bytes)
    }
}

nonisolated struct ByteReader: LittleEndianByteReading {
    let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingByteCount >= 1 else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let bytes = try readBytes(count: length)
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, remainingByteCount >= count else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        let start = data.startIndex + offset
        defer { offset += count }
        return data.subdata(in: start..<(start + count))
    }

    mutating func load<T>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingByteCount >= size else {
            throw ScanSnapshotCacheError.corruptData("unexpected end of data")
        }
        // withUnsafeBytes rebases the buffer to index 0 regardless of the
        // Data's startIndex, so the plain running offset is the right one.
        defer { offset += size }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: type)
        }
    }
}
