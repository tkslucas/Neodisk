import Foundation
import Testing
@testable import NeodiskKit

/// The streaming payload compressor must stay byte-compatible with the
/// NSData LZFSE stream earlier versions wrote (and the decoder reads).
@Suite struct ScanSnapshotCodecCompressionTests {
    /// Several output chunks' worth of compressible-but-not-trivial bytes:
    /// repeated path-like records with varying integers, like a real payload.
    private func makePayload(recordCount: Int) -> Data {
        var data = Data()
        data.reserveCapacity(recordCount * 48)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<recordCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data.append(contentsOf: "/Users/someone/Library/Caches/item-\(index % 997)/".utf8)
            withUnsafeBytes(of: state.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func streamedPayloadMatchesNSDataLZFSE() throws {
        let payload = makePayload(recordCount: 120_000)
        #expect(payload.count > 4 << 20)

        var streamed = Data()
        try ScanSnapshotCodec.appendCompressedPayload(payload, to: &streamed)
        let reference = try (payload as NSData).compressed(using: .lzfse) as Data

        #expect(streamed == reference)
        #expect(try ScanSnapshotCodec.decompressPayload(streamed) == payload)
    }

    @Test func appendsAfterExistingBytes() throws {
        let payload = makePayload(recordCount: 500)
        var output = Data([0xAB, 0xCD])
        try ScanSnapshotCodec.appendCompressedPayload(payload, to: &output)

        #expect(output.prefix(2) == Data([0xAB, 0xCD]))
        #expect(try ScanSnapshotCodec.decompressPayload(output.dropFirst(2)) == payload)
    }

    @Test func tinyPayloadRoundTrips() throws {
        let payload = Data([0, 0, 0, 0])
        var output = Data()
        try ScanSnapshotCodec.appendCompressedPayload(payload, to: &output)

        #expect(try ScanSnapshotCodec.decompressPayload(output) == payload)
    }
}
