import Foundation
import Testing
@testable import NeodiskKit

/// `NEODISK_DECODE_BENCH=<file.ndscan>`: decodes a real snapshot `NEODISK_BENCH_ITERATIONS` times (default 7) and
/// prints the best and median, then times a save's digest and encode. `NEODISK_DECODE_CHECKSUM=1` also prints a
/// checksum of every record and the topology, to compare decoders. Run in release:
/// `swift test -c release -Xswiftc -enable-testing --filter SnapshotDecodeBench`.
@Suite(.serialized) struct SnapshotDecodeBenchTests {
    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEODISK_DECODE_BENCH"] != nil))
    func benchDecode() throws {
        let environment = ProcessInfo.processInfo.environment
        let data = try Data(contentsOf: URL(filePath: try #require(environment["NEODISK_DECODE_BENCH"])))
        let iterations = environment["NEODISK_BENCH_ITERATIONS"].flatMap(Int.init) ?? 7
        let clock = ContinuousClock()
        var times: [Duration] = []
        var decoded: ScanSnapshot?
        for _ in 0..<iterations {
            decoded = nil
            times.append(clock.measure { decoded = try? ScanSnapshotCodec.decode(data) })
        }
        let snapshot = try #require(decoded)
        times.sort()
        print(
            "DECODEBENCH nodes=\(snapshot.treeStore.nodeCount) bytes=\(data.count)"
                + " best=\(Self.milliseconds(times[0]))ms median=\(Self.milliseconds(times[times.count / 2]))ms"
        )

        if environment["NEODISK_DECODE_CHECKSUM"] == "1" {
            let storage = snapshot.treeStore.storage
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            func fold(_ text: String) {
                for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            }
            for (index, node) in storage.nodes.enumerated() {
                fold(snapshotRecordSignature(node))
                fold("\(storage.parentIndices[index]) \(storage.childStarts[index]) \(storage.nodeHashes[index])")
            }
            fold("\(storage.childSlots) \(snapshot.treeStore.rootID) \(snapshot.scanWarnings.count)")
            print("DECODECHECKSUM \(String(hash, radix: 16))")
        }

        let digestSince = clock.now
        let digest = try ScanChangeList.contentDigest(of: snapshot.treeStore, checkCancellation: {})
        let digestTime = clock.now - digestSince
        let encodeTime = try clock.measure {
            _ = try ScanSnapshotCodec.encode(
                snapshot, version: ScanSnapshotCache.currentFormatVersion, changeDigest: digest
            )
        }
        print("ENCODEBENCH digest=\(Self.milliseconds(digestTime))ms encode=\(Self.milliseconds(encodeTime))ms")
    }
}
