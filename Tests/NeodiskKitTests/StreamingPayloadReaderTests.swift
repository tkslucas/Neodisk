//
//  StreamingPayloadReaderTests.swift
//  NeodiskKitTests
//
//  The snapshot decoder parses payloads as they decompress, through a
//  refilling window. Reads must come out identical whatever the window
//  size — values straddling a refill, strings longer than the window — and
//  a truncated payload must fail rather than read short.
//

import Foundation
import Testing
@testable import NeodiskKit

@Suite struct StreamingPayloadReaderTests {
    private let longString = String(repeating: "nested/folder/", count: 40)

    private func compressedPayload() throws -> Data {
        var writer = ByteWriter()
        for index in 0..<2_000 {
            writer.append(UInt32(index))
            writer.appendString("file-\(index).txt")
            writer.append(Int64(index) * 4096)
            writer.append(UInt8(index % 256))
        }
        writer.appendString(longString)
        var compressed = Data()
        try ScanSnapshotCodec.appendCompressedPayload(writer.data, to: &compressed)
        return compressed
    }

    private func readBack(_ streamingReader: StreamingPayloadReader) throws {
        var reader = streamingReader
        for index in 0..<2_000 {
            #expect(try reader.readUInt32() == UInt32(index))
            #expect(try reader.readString() == "file-\(index).txt")
            #expect(try reader.readInt64() == Int64(index) * 4096)
            #expect(try reader.readUInt8() == UInt8(index % 256))
        }
        #expect(try reader.readString() == longString)
        #expect(reader.isAtEnd)
    }

    @Test(arguments: [7, 64, 4 << 20])
    func readsMatchWhateverTheWindowSize(windowSize: Int) throws {
        let reader = StreamingPayloadReader(
            source: try PayloadDecompressor(compressed: try compressedPayload()),
            windowSize: windowSize
        )
        try readBack(reader)
    }

    @Test func truncatedPayloadFails() throws {
        let compressed = try compressedPayload()
        let reader = StreamingPayloadReader(
            source: try PayloadDecompressor(compressed: compressed.dropLast(8)),
            windowSize: 64
        )
        #expect(throws: ScanSnapshotCacheError.self) {
            try readBack(reader)
        }
    }
}
