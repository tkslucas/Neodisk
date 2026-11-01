import Foundation
import Testing
@testable import NeodiskKit

/// Builds FILE records the way NTFS lays them out on disk, update sequence included.
enum SyntheticNTFS {
    static let recordSize = 1024

    struct Record {
        var number: UInt32
        var sequence: UInt16 = 1
        var isInUse = true
        var isDirectory = false
        var base: UInt64 = 0
        var linkCount: UInt16 = 1
        var attributes: [[UInt8]] = []

        func bytes(updateSequence: UInt16 = 0x0042) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: recordSize)
            let arrayCount = recordSize / 512 + 1
            put(&bytes, 0, UInt32(0x454C_4946))
            put(&bytes, 4, UInt16(0x30))
            put(&bytes, 6, UInt16(arrayCount))
            put(&bytes, 0x10, sequence)
            put(&bytes, 0x12, linkCount)
            let firstAttribute = align8(0x30 + arrayCount * 2)
            put(&bytes, 0x14, UInt16(firstAttribute))
            put(&bytes, 0x16, UInt16((isInUse ? 1 : 0) | (isDirectory ? 2 : 0)))
            put(&bytes, 0x1C, UInt32(recordSize))
            put(&bytes, 0x20, base)
            put(&bytes, 0x2C, number)
            var offset = firstAttribute
            for attribute in attributes {
                bytes.replaceSubrange(offset..<(offset + attribute.count), with: attribute)
                offset += attribute.count
            }
            put(&bytes, offset, UInt32(0xFFFF_FFFF))
            offset += 8
            put(&bytes, 0x18, UInt32(offset))
            // Protect: save each sector's tail in the array, stamp the sequence number there.
            put(&bytes, 0x30, updateSequence)
            for sector in 1..<arrayCount {
                let tail = sector * 512 - 2
                bytes[0x30 + sector * 2] = bytes[tail]
                bytes[0x30 + sector * 2 + 1] = bytes[tail + 1]
                put(&bytes, tail, updateSequence)
            }
            return bytes
        }
    }

    static func align8(_ value: Int) -> Int { (value + 7) & ~7 }

    static func put<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ offset: Int, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for index in 0..<raw.count { bytes[offset + index] = raw[index] }
        }
    }

    static func resident(type: UInt32, name: String? = nil, value: [UInt8], flags: UInt16 = 0) -> [UInt8] {
        let nameUnits = Array((name ?? "").utf16)
        let valueOffset = align8(0x18 + nameUnits.count * 2)
        var bytes = [UInt8](repeating: 0, count: align8(valueOffset + value.count))
        put(&bytes, 0, type)
        put(&bytes, 4, UInt32(bytes.count))
        bytes[9] = UInt8(nameUnits.count)
        put(&bytes, 10, UInt16(0x18))
        put(&bytes, 12, flags)
        for (index, unit) in nameUnits.enumerated() { put(&bytes, 0x18 + index * 2, unit) }
        put(&bytes, 0x10, UInt32(value.count))
        put(&bytes, 0x14, UInt16(valueOffset))
        bytes.replaceSubrange(valueOffset..<(valueOffset + value.count), with: value)
        return bytes
    }

    static func standardInformation(attributes: UInt32, lastWrite: Int64 = 133_000_000_000_000_000) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 0x48)
        put(&value, 0, Int64(132_000_000_000_000_000))
        put(&value, 8, lastWrite)
        put(&value, 0x20, attributes)
        return resident(type: 0x10, value: value)
    }

    static func fileName(parent: UInt64, _ name: String, namespace: UInt8 = 1) -> [UInt8] {
        let units = Array(name.utf16)
        var value = [UInt8](repeating: 0, count: 0x42 + units.count * 2)
        put(&value, 0, parent)
        value[0x40] = UInt8(units.count)
        value[0x41] = namespace
        for (index, unit) in units.enumerated() { put(&value, 0x42 + index * 2, unit) }
        return resident(type: 0x30, value: value)
    }

    static func residentData(length: Int, name: String? = nil) -> [UInt8] {
        resident(type: 0x80, name: name, value: [UInt8](repeating: 0xAB, count: length))
    }

    static func nonResidentData(
        allocated: Int64,
        real: Int64,
        totalAllocated: Int64? = nil,
        flags: UInt16 = 0,
        lowestVCN: UInt64 = 0,
        runs: [UInt8] = [0x11, 0x01, 0x10, 0x00]
    ) -> [UInt8] {
        let headerSize = totalAllocated == nil ? 0x40 : 0x48
        var bytes = [UInt8](repeating: 0, count: align8(headerSize + runs.count))
        put(&bytes, 0, UInt32(0x80))
        put(&bytes, 4, UInt32(bytes.count))
        bytes[8] = 1
        put(&bytes, 10, UInt16(headerSize))
        put(&bytes, 12, flags)
        put(&bytes, 0x10, lowestVCN)
        put(&bytes, 0x20, UInt16(headerSize))
        put(&bytes, 0x28, allocated)
        put(&bytes, 0x30, real)
        put(&bytes, 0x38, real)
        if let totalAllocated { put(&bytes, 0x40, totalAllocated) }
        bytes.replaceSubrange(headerSize..<(headerSize + runs.count), with: runs)
        return bytes
    }

    static func namedNonResidentData(name: String, allocated: Int64, real: Int64) -> [UInt8] {
        let units = Array(name.utf16)
        let runsOffset = align8(0x40 + units.count * 2)
        let runs: [UInt8] = [0x11, 0x02, 0x20, 0x00]
        var bytes = [UInt8](repeating: 0, count: align8(runsOffset + runs.count))
        put(&bytes, 0, UInt32(0x80))
        put(&bytes, 4, UInt32(bytes.count))
        bytes[8] = 1
        bytes[9] = UInt8(units.count)
        put(&bytes, 10, UInt16(0x40))
        for (index, unit) in units.enumerated() { put(&bytes, 0x40 + index * 2, unit) }
        put(&bytes, 0x20, UInt16(runsOffset))
        put(&bytes, 0x28, allocated)
        put(&bytes, 0x30, real)
        put(&bytes, 0x38, real)
        bytes.replaceSubrange(runsOffset..<(runsOffset + runs.count), with: runs)
        return bytes
    }

    static func reparsePoint(tag: UInt32) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 8)
        put(&value, 0, tag)
        return resident(type: 0xC0, value: value)
    }

    static func attributeList(_ entries: [(type: UInt32, lowestVCN: UInt64, segment: UInt64)]) -> [UInt8] {
        var value: [UInt8] = []
        for entry in entries {
            var item = [UInt8](repeating: 0, count: 0x20)
            put(&item, 0, entry.type)
            put(&item, 4, UInt16(0x20))
            item[7] = 0x1A
            put(&item, 8, entry.lowestVCN)
            put(&item, 0x10, entry.segment)
            value += item
        }
        return resident(type: 0x20, value: value)
    }

    static func parse(_ bytes: [UInt8], options: NTFSRecordParser.Options = .index) throws -> NTFSFileRecord {
        var bytes = bytes
        var record = NTFSFileRecord()
        try bytes.withUnsafeMutableBytes { raw in
            try NTFSRecordParser.applyFixups(raw)
            try NTFSRecordParser.parse(UnsafeRawBufferPointer(raw), into: &record, options: options)
        }
        return record
    }

    static func name(_ slice: NTFSFileNameSlice, in bytes: [UInt8]) throws -> String {
        var fixed = bytes
        try fixed.withUnsafeMutableBytes { try NTFSRecordParser.applyFixups($0) }
        let units = (0..<slice.nameLength).map {
            UInt16(fixed[slice.nameOffset + $0 * 2]) | UInt16(fixed[slice.nameOffset + $0 * 2 + 1]) << 8
        }
        return String(decoding: units, as: UTF16.self)
    }
}

@Suite struct NTFSRecordParserTests {
    @Test func fixupsRestoreSectorTailsAndCatchTornWrites() throws {
        var record = SyntheticNTFS.Record(number: 40)
        // A name spanning the first sector boundary, so its bytes are only right after the fixup.
        record.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20),
            SyntheticNTFS.residentData(length: 300),
            SyntheticNTFS.fileName(parent: NTFSFileReference(record: 5, sequence: 5).rawValue, "spans-the-sector-tail.txt"),
        ]
        let bytes = record.bytes()
        let parsed = try SyntheticNTFS.parse(bytes)
        #expect(parsed.fileNames.count == 1)
        #expect(try SyntheticNTFS.name(parsed.fileNames[0], in: bytes) == "spans-the-sector-tail.txt")

        var torn = bytes
        torn[1022] ^= 0xFF
        #expect(throws: NTFSRecordError.badFixup) { try SyntheticNTFS.parse(torn) }

        var notARecord = bytes
        notARecord[0] = 0x42
        #expect(throws: NTFSRecordError.badSignature) { try SyntheticNTFS.parse(notARecord) }
    }

    @Test func parsesHeaderTimesAttributesAndNames() throws {
        let parent = NTFSFileReference(record: 30, sequence: 7)
        var record = SyntheticNTFS.Record(number: 41, sequence: 9, linkCount: 1)
        record.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x22, lastWrite: 133_444_555_666_777_888),
            SyntheticNTFS.fileName(parent: parent.rawValue, "PROGRA~1", namespace: NTFSFileNameNamespace.dos),
            SyntheticNTFS.fileName(parent: parent.rawValue, "Program Files", namespace: NTFSFileNameNamespace.win32),
            SyntheticNTFS.residentData(length: 13),
        ]
        let bytes = record.bytes()
        let parsed = try SyntheticNTFS.parse(bytes)
        #expect(parsed.recordNumber == 41)
        #expect(parsed.sequenceNumber == 9)
        #expect(parsed.isInUse && !parsed.isDirectory && parsed.isBaseRecord)
        #expect(parsed.hasStandardInformation)
        #expect(parsed.fileAttributes == 0x22)
        #expect(parsed.lastWriteTime == 133_444_555_666_777_888)
        #expect(parsed.fileNames.map(\.namespace) == [NTFSFileNameNamespace.dos, NTFSFileNameNamespace.win32])
        #expect(parsed.fileNames.allSatisfy { $0.parent == parent })
        #expect(try SyntheticNTFS.name(parsed.fileNames[1], in: bytes) == "Program Files")
        #expect(parsed.unnamedData == NTFSDataSizes(
            logicalSize: 13, allocatedSize: 13, totalAllocated: nil,
            isResident: true, isCompressed: false, isSparse: false
        ))
        #expect(parsed.unnamedData?.listedAllocationSize == 16)
    }

    @Test func namedStreamsDoNotCountAsTheFileData() throws {
        var record = SyntheticNTFS.Record(number: 42)
        record.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20),
            SyntheticNTFS.residentData(length: 100, name: "Zone.Identifier"),
        ]
        #expect(try SyntheticNTFS.parse(record.bytes()).unnamedData == nil)
    }

    @Test func nonResidentSizesComeFromTheFirstExtentOnly() throws {
        var plain = SyntheticNTFS.Record(number: 43)
        plain.attributes = [SyntheticNTFS.nonResidentData(allocated: 8192, real: 5000)]
        let sizes = try #require(try SyntheticNTFS.parse(plain.bytes()).unnamedData)
        #expect(!sizes.isResident && sizes.logicalSize == 5000 && sizes.listedAllocationSize == 8192)

        var compressed = SyntheticNTFS.Record(number: 44)
        compressed.attributes = [SyntheticNTFS.nonResidentData(
            allocated: 65536, real: 60000, totalAllocated: 12288, flags: 0x0001
        )]
        let compressedSizes = try #require(try SyntheticNTFS.parse(compressed.bytes()).unnamedData)
        #expect(compressedSizes.isCompressed && compressedSizes.listedAllocationSize == 12288)

        var sparse = SyntheticNTFS.Record(number: 45)
        sparse.attributes = [SyntheticNTFS.nonResidentData(
            allocated: 1 << 30, real: 1 << 30, totalAllocated: 4096, flags: 0x8000
        )]
        let sparseSizes = try #require(try SyntheticNTFS.parse(sparse.bytes()).unnamedData)
        #expect(sparseSizes.isSparse && sparseSizes.listedAllocationSize == 4096 && sparseSizes.logicalSize == 1 << 30)

        var laterExtent = SyntheticNTFS.Record(number: 46, base: NTFSFileReference(record: 43, sequence: 1).rawValue)
        laterExtent.attributes = [SyntheticNTFS.nonResidentData(allocated: 0, real: 0, lowestVCN: 16)]
        let extent = try SyntheticNTFS.parse(laterExtent.bytes(), options: .fileTable)
        #expect(extent.unnamedData == nil)
        #expect(!extent.isBaseRecord && extent.baseRecord.recordNumber == 43)
        #expect(extent.unnamedDataRuns == [NTFSDataRun(startVCN: 16, clusterCount: 1, lcn: 16)])
    }

    @Test func reparsePointsAndAttributeListsAreReported() throws {
        var junction = SyntheticNTFS.Record(number: 47, isDirectory: true)
        junction.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x410),
            SyntheticNTFS.reparsePoint(tag: 0xA000_0003),
        ]
        let parsed = try SyntheticNTFS.parse(junction.bytes())
        #expect(parsed.isDirectory && parsed.hasReparsePoint && parsed.reparseTag == 0xA000_0003)

        var spilled = SyntheticNTFS.Record(number: 48)
        let segment = NTFSFileReference(record: 49, sequence: 2).rawValue
        spilled.attributes = [
            SyntheticNTFS.standardInformation(attributes: 0x20),
            SyntheticNTFS.attributeList([(0x10, 0, 48), (0x80, 0, segment), (0x80, 900, segment)]),
        ]
        let withList = try SyntheticNTFS.parse(spilled.bytes(), options: .fileTable)
        #expect(withList.hasAttributeList && withList.attributeListIsResident)
        #expect(withList.attributeList.map(\.type) == [0x10, 0x80, 0x80])
        #expect(withList.attributeList[2].lowestVCN == 900)
        #expect(withList.attributeList[2].segment == NTFSFileReference(rawValue: segment))
    }

    @Test func dataRunsDecodeSignedDeltasAndHoles() throws {
        // 0x20 clusters at 0x1000, a 0x10-cluster hole, 0x08 clusters 0x100 back, then the terminator.
        let runs: [UInt8] = [0x21, 0x20, 0x00, 0x10, 0x01, 0x10, 0x21, 0x08, 0x00, 0xFF, 0x00]
        var decoded: [NTFSDataRun] = []
        try runs.withUnsafeBytes { try NTFSRecordParser.decodeDataRuns($0, startingVCN: 0, into: &decoded) }
        #expect(decoded == [
            NTFSDataRun(startVCN: 0, clusterCount: 0x20, lcn: 0x1000),
            NTFSDataRun(startVCN: 0x20, clusterCount: 0x10, lcn: nil),
            NTFSDataRun(startVCN: 0x30, clusterCount: 0x08, lcn: 0x0F00),
        ])

        let unterminated: [UInt8] = [0x11, 0x05]
        var ignored: [NTFSDataRun] = []
        #expect(throws: NTFSRecordError.badDataRun) {
            try unterminated.withUnsafeBytes { try NTFSRecordParser.decodeDataRuns($0, startingVCN: 0, into: &ignored) }
        }
        let negativeStart: [UInt8] = [0x11, 0x05, 0xF0, 0x00]
        #expect(throws: NTFSRecordError.badDataRun) {
            try negativeStart.withUnsafeBytes { try NTFSRecordParser.decodeDataRuns($0, startingVCN: 0, into: &ignored) }
        }
    }

    @Test func garbledAttributeLengthsThrowInsteadOfTrapping() throws {
        var record = SyntheticNTFS.Record(number: 50)
        record.attributes = [SyntheticNTFS.standardInformation(attributes: 0x20)]
        var bytes = record.bytes()
        // The first attribute's length now runs past the used size.
        SyntheticNTFS.put(&bytes, 0x38 + 4, UInt32(4096))
        #expect(throws: NTFSRecordError.badAttribute) { try SyntheticNTFS.parse(bytes) }

        var free = SyntheticNTFS.Record(number: 51, isInUse: false)
        free.attributes = [SyntheticNTFS.fileName(parent: 5, "gone.txt")]
        let parsed = try SyntheticNTFS.parse(free.bytes())
        #expect(!parsed.isInUse && parsed.fileNames.isEmpty)
    }
}
